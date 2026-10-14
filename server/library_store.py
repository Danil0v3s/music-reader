"""Each user's score library: their scores, original PDFs and collections, synced across their devices.

Scores are stored as the app's JSON (lossless: bowings, fingerings, everything the editor knows), opaque to
the server apart from the title and composer it lists. Every change carries the client's modification
time; deletions leave a tombstone so a device that still has the score learns it was deleted instead of
uploading it again. Collections are one JSON document per user.

Rows live in the database (db.py); original PDFs are files under <data>/originals/<user>/<score>.pdf.
Every method takes the user: one user can never read or change another's library through this class.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path

from db import Database

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def valid_id(score_id: str) -> bool:
    return bool(UUID_RE.match(score_id))


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _score_doc(body: bytes) -> dict:
    doc = json.loads(body)
    if not isinstance(doc, dict):
        raise ValueError("a score must be a JSON object")
    return doc


class LibraryStore:
    def __init__(self, db: Database, originals: Path):
        self.db = db
        self.originals = originals
        originals.mkdir(parents=True, exist_ok=True)

    def _original_path(self, user: str, score_id: str) -> Path:
        return self.originals / user / f"{score_id.upper()}.pdf"

    # Listing

    def listing(self, user: str) -> dict:
        rows = self.db.query("SELECT id, modified, deleted, title, composer, has_original FROM scores WHERE user_id = ?", (user,))
        scores = [{"id": r["id"], "modified": r["modified"], "deleted": bool(r["deleted"]), "title": r["title"],
                   "composer": r["composer"], "original": "pdf" if r["has_original"] else None} for r in rows]
        c = self.db.one("SELECT modified FROM collections WHERE user_id = ?", (user,))
        return {"scores": scores, "collections": {"modified": c["modified"] if c else None}}

    # Scores

    def get_score(self, user: str, score_id: str) -> bytes | None:
        r = self.db.one("SELECT body FROM scores WHERE user_id = ? AND id = ? AND deleted = 0", (user, score_id.upper()))
        return bytes(r["body"]) if r and r["body"] is not None else None

    def put_score(self, user: str, score_id: str, body: bytes, modified: float, imported_from: dict | None = None) -> None:
        """Stores a score. Raises ValueError if the body isn't a JSON object."""
        doc = _score_doc(body)
        with self.db.tx() as c:
            existing = c.execute("SELECT deleted, has_original FROM scores WHERE user_id = ? AND id = ?",
                                 (user, score_id.upper())).fetchone()
            # A score coming back after a deletion has no original any more.
            has_original = bool(existing and not existing["deleted"] and existing["has_original"])
            c.execute("""INSERT INTO scores (user_id, id, modified, deleted, title, composer, body, has_original, imported_from)
                         VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?)
                         ON CONFLICT (user_id, id) DO UPDATE SET modified = excluded.modified, deleted = 0,
                             title = excluded.title, composer = excluded.composer, body = excluded.body,
                             has_original = excluded.has_original,
                             imported_from = COALESCE(excluded.imported_from, scores.imported_from)""",
                      (user, score_id.upper(), modified, str(doc.get("title", ""))[:200], str(doc.get("composer", ""))[:200],
                       body, int(has_original), json.dumps(imported_from) if imported_from else None))

    def delete_score(self, user: str, score_id: str, modified: float) -> None:
        # The tombstone is recorded even for an unknown id: another device may still upload it.
        with self.db.tx() as c:
            c.execute("""INSERT INTO scores (user_id, id, modified, deleted, body, has_original) VALUES (?, ?, ?, 1, NULL, 0)
                         ON CONFLICT (user_id, id) DO UPDATE SET modified = excluded.modified, deleted = 1, body = NULL,
                             has_original = 0""", (user, score_id.upper(), modified))
        self._original_path(user, score_id).unlink(missing_ok=True)

    # Originals

    def get_original(self, user: str, score_id: str) -> bytes | None:
        r = self.db.one("SELECT has_original FROM scores WHERE user_id = ? AND id = ? AND deleted = 0", (user, score_id.upper()))
        if not r or not r["has_original"]:
            return None
        try:
            return self._original_path(user, score_id).read_bytes()
        except FileNotFoundError:
            return None

    def put_original(self, user: str, score_id: str, body: bytes) -> bool:
        """Stores the original PDF of an existing score. False if there is no such score."""
        if not body.startswith(b"%PDF"):
            raise ValueError("the original must be a PDF")
        with self.db.tx() as c:
            r = c.execute("SELECT deleted FROM scores WHERE user_id = ? AND id = ?", (user, score_id.upper())).fetchone()
            if not r or r["deleted"]:
                return False
            _atomic_write(self._original_path(user, score_id), body)
            c.execute("UPDATE scores SET has_original = 1 WHERE user_id = ? AND id = ?", (user, score_id.upper()))
        return True

    # Collections

    def get_collections(self, user: str) -> bytes | None:
        r = self.db.one("SELECT body FROM collections WHERE user_id = ?", (user,))
        return bytes(r["body"]) if r else None

    def put_collections(self, user: str, body: bytes, modified: float) -> None:
        doc = json.loads(body)
        if not isinstance(doc, dict):
            raise ValueError("collections must be a JSON object")
        with self.db.tx() as c:
            c.execute("""INSERT INTO collections (user_id, modified, body) VALUES (?, ?, ?)
                         ON CONFLICT (user_id) DO UPDATE SET modified = excluded.modified, body = excluded.body""",
                      (user, modified, body))

    # Whole libraries

    def move_all(self, from_user: str, to_user: str, now: float) -> int:
        """Moves one user's library into another's (a guest signing in to an existing account). Where both
        have the same score, the newer one wins; collections are combined. Returns the scores moved."""
        moved = 0
        for r in self.db.query("SELECT * FROM scores WHERE user_id = ?", (from_user,)):
            target = self.db.one("SELECT modified FROM scores WHERE user_id = ? AND id = ?", (to_user, r["id"]))
            if target and target["modified"] >= r["modified"]:
                continue
            with self.db.tx() as c:
                c.execute("DELETE FROM scores WHERE user_id = ? AND id = ?", (to_user, r["id"]))
                c.execute("UPDATE scores SET user_id = ? WHERE user_id = ? AND id = ?", (to_user, from_user, r["id"]))
            src, dst = self._original_path(from_user, r["id"]), self._original_path(to_user, r["id"])
            if r["has_original"] and src.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                os.replace(src, dst)
            moved += not r["deleted"]
        mine, theirs = self.get_collections(from_user), self.get_collections(to_user)
        if mine:
            combined = json.loads(theirs) if theirs else {"collections": []}
            known = {c.get("id") for c in combined.get("collections", [])}
            combined["collections"] = combined.get("collections", []) + [c for c in json.loads(mine).get("collections", [])
                                                                        if c.get("id") not in known]
            stamp = _iso(now)
            combined["modified"] = stamp
            self.put_collections(to_user, json.dumps(combined).encode(), now)
        self.delete_user(from_user)
        return moved

    def delete_user(self, user: str) -> None:
        """Removes everything a user stored (the rows go with the user; this clears the files too)."""
        with self.db.tx() as c:
            c.execute("DELETE FROM scores WHERE user_id = ?", (user,))
            c.execute("DELETE FROM collections WHERE user_id = ?", (user,))
        shutil.rmtree(self.originals / user, ignore_errors=True)

    def import_legacy(self, folder: Path, user: str) -> int:
        """Imports a single-user library from before accounts (<data>/library: index.json, scores/,
        originals/, collections.json) into a user's library. Returns the scores imported."""
        index = json.loads((folder / "index.json").read_text())
        count = 0
        for score_id, entry in index.get("scores", {}).items():
            if entry.get("deleted"):
                self.delete_score(user, score_id, entry["modified"])
                continue
            path = folder / "scores" / f"{score_id}.json"
            if not path.exists():
                continue
            self.put_score(user, score_id, path.read_bytes(), entry["modified"])
            original = folder / "originals" / f"{score_id}.pdf"
            if entry.get("original") and original.exists():
                self.put_original(user, score_id, original.read_bytes())
            count += 1
        collections = folder / "collections.json"
        if collections.exists():
            self.put_collections(user, collections.read_bytes(), index.get("collections", {}).get("modified") or 0)
        return count


def _iso(t: float) -> str:
    """A time the way the app encodes dates (ISO 8601, milliseconds, UTC)."""
    import datetime
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
