"""Sharing a score or a collection with a code.

Nothing is shared unless its owner makes a code for it. Anyone signed in (guests too) who has the code can
look at the shared music, read-only, and import their own copy, which they can then edit like anything
else in their library. A share points at the live score or collection: people opening the code later see
the owner's corrections; copies already imported don't change. The owner can stop sharing at any time.

Only the notation is ever shared, never the original scan or PDF (much printed music is under copyright).

Codes are 8 characters from an alphabet without look-alikes (no 0/O, 1/I/L), about 40 bits, random, not
derived from anything; they're shown as XXXX-XXXX and typed in any case, with or without the dash.
"""

from __future__ import annotations

import json
import secrets
import time
import uuid

from accounts import AccountError
from db import Database
from library_store import LibraryStore, _iso

ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 8


def normalise_code(text: str) -> str:
    return "".join(ch for ch in (text or "").upper() if ch.isalnum())


def display_code(code: str) -> str:
    return f"{code[:4]}-{code[4:]}"


class Shares:
    def __init__(self, db: Database, library: LibraryStore, public_url: str):
        self.db = db
        self.library = library
        self.public_url = public_url.rstrip("/")

    # Owners

    def _describe(self, row) -> dict:
        title = self._target_title(row["user_id"], row["kind"], row["target_id"])
        return {"code": display_code(row["code"]), "url": f"{self.public_url}/s/{row['code']}", "kind": row["kind"],
                "id": row["target_id"], "title": title, "created": row["created"], "imports": row["imports"]}

    def _target_title(self, user: str, kind: str, target: str) -> str | None:
        if kind == "score":
            r = self.db.one("SELECT title FROM scores WHERE user_id = ? AND id = ? AND deleted = 0", (user, target.upper()))
            return r["title"] if r else None
        collection = self._collection(user, target)
        return collection.get("name") if collection else None

    def _collection(self, user: str, collection_id: str) -> dict | None:
        doc = self.library.get_collections(user)
        if not doc:
            return None
        return next((c for c in json.loads(doc).get("collections", []) if str(c.get("id", "")).upper() == collection_id.upper()), None)

    def create(self, user: str, kind: str, target: str) -> dict:
        """A code for one of the user's scores or collections (the existing one, if it's already shared)."""
        if kind not in ("score", "collection"):
            raise AccountError("Share a score or a collection.", 400, "bad_kind")
        target = target.upper()
        if self._target_title(user, kind, target) is None:
            raise AccountError("There's no such score or collection in your library. Let it sync first.", 404, "not_found")
        with self.db.tx() as c:
            row = c.execute("SELECT * FROM shares WHERE user_id = ? AND kind = ? AND target_id = ? AND revoked IS NULL",
                            (user, kind, target)).fetchone()
            if row is None:
                while True:
                    code = "".join(secrets.choice(ALPHABET) for _ in range(CODE_LENGTH))
                    if not c.execute("SELECT 1 FROM shares WHERE code = ?", (code,)).fetchone():
                        break
                c.execute("INSERT INTO shares (code, kind, user_id, target_id, created) VALUES (?, ?, ?, ?, ?)",
                          (code, kind, user, target, time.time()))
                row = c.execute("SELECT * FROM shares WHERE code = ?", (code,)).fetchone()
        return self._describe(row)

    def mine(self, user: str) -> list[dict]:
        rows = self.db.query("SELECT * FROM shares WHERE user_id = ? AND revoked IS NULL ORDER BY created DESC", (user,))
        return [d for d in (self._describe(r) for r in rows) if d["title"] is not None]

    def revoke(self, user: str, code: str) -> None:
        with self.db.tx() as c:
            n = c.execute("UPDATE shares SET revoked = ? WHERE code = ? AND user_id = ? AND revoked IS NULL",
                          (time.time(), normalise_code(code), user)).rowcount
        if n == 0:
            raise AccountError("No such share.", 404, "not_found")

    def revoke_missing(self, user: str) -> None:
        """Stops shares whose score was deleted or whose collection is gone from the collections document."""
        for r in self.db.query("SELECT code, kind, target_id FROM shares WHERE user_id = ? AND revoked IS NULL", (user,)):
            if self._target_title(user, r["kind"], r["target_id"]) is None:
                with self.db.tx() as c:
                    c.execute("UPDATE shares SET revoked = ? WHERE code = ?", (time.time(), r["code"]))

    # Anyone with the code

    def _active(self, code: str):
        row = self.db.one("SELECT * FROM shares WHERE code = ? AND revoked IS NULL", (normalise_code(code),))
        if row is None or self._target_title(row["user_id"], row["kind"], row["target_id"]) is None:
            raise AccountError("This code doesn't work: it's mistyped, or the owner stopped sharing.", 404, "share_not_found")
        return row

    def _owner_name(self, user: str) -> str:
        r = self.db.one("SELECT display_name FROM users WHERE id = ?", (user,))
        return (r["display_name"] if r else "") or "a Music Reader user"

    def _scores_of(self, row) -> list[tuple[str, dict]]:
        """The shared scores as (id, score JSON), notation only."""
        ids = [row["target_id"]] if row["kind"] == "score" else \
            [str(i).upper() for i in (self._collection(row["user_id"], row["target_id"]) or {}).get("scoreIds", [])]
        out = []
        for score_id in ids:
            body = self.library.get_score(row["user_id"], score_id)
            if body is not None:
                out.append((score_id, json.loads(body)))
        return out

    def summary(self, code: str) -> dict:
        """Enough for a web page about the code: what it is and whose (no notation)."""
        row = self._active(code)
        return {"kind": row["kind"], "title": self._target_title(row["user_id"], row["kind"], row["target_id"]),
                "owner": self._owner_name(row["user_id"]), "code": display_code(row["code"])}

    def open(self, code: str) -> dict:
        """The shared music, read-only: a score, or a collection's name and scores."""
        row = self._active(code)
        out = {**self.summary(code)}
        scores = [doc for _, doc in self._scores_of(row)]
        if row["kind"] == "score":
            out["score"] = scores[0]
        else:
            out["collection"] = {"name": out["title"], "scores": scores}
        return out

    def import_to(self, code: str, user: str) -> dict:
        """Copies the shared music into `user`'s library: new ids, editable, remembering where it came from.
        A collection becomes a new collection holding the copies."""
        row = self._active(code)
        now = round(time.time(), 3)
        stamp = _iso(now)
        origin = {"code": display_code(row["code"]), "owner": self._owner_name(row["user_id"]),
                  "title": self._target_title(row["user_id"], row["kind"], row["target_id"])}
        copies = []
        for _, doc in self._scores_of(row):
            new_id = str(uuid.uuid4()).upper()
            # The copy's own dates match the server's record, so sync sees it as up to date once downloaded.
            doc.update(id=new_id, created=stamp, modified=stamp, importedFrom=origin)
            self.library.put_score(user, new_id, json.dumps(doc).encode(), now, imported_from=origin)
            copies.append(new_id)
        collection_id = None
        if row["kind"] == "collection":
            collection_id = str(uuid.uuid4()).upper()
            existing = self.library.get_collections(user)
            doc = json.loads(existing) if existing else {"collections": []}
            doc.setdefault("collections", []).append({"id": collection_id, "name": origin["title"], "scoreIds": copies, "created": stamp})
            doc["modified"] = stamp
            self.library.put_collections(user, json.dumps(doc).encode(), now)
        with self.db.tx() as c:
            c.execute("UPDATE shares SET imports = imports + 1 WHERE code = ?", (row["code"],))
        return {"scores": copies, "collection": collection_id}
