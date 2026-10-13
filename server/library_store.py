"""The user's score library, kept on their own server so every device sees the same scores.

Scores are stored as the app's JSON (lossless: bowings, fingerings, everything the editor knows), opaque to
the server apart from the title and composer it lists. An imported score can carry its original PDF.
Collections are one JSON document. Every change carries the client's modification time; deletions leave a
tombstone so a device that still has the score learns it was deleted instead of uploading it again.

Layout under <data>/library/:
    index.json                      {"scores": {id: {modified, deleted, title, composer, original}}, "collections": {modified}}
    scores/<id>.json                the score
    originals/<id>.pdf              the imported original
    collections.json                the collections document
"""

from __future__ import annotations

import json
import os
import re
import threading
from pathlib import Path

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def valid_id(score_id: str) -> bool:
    return bool(UUID_RE.match(score_id))


def _atomic_write(path: Path, data: bytes) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


class LibraryStore:
    def __init__(self, root: Path):
        self.root = root
        self.scores_dir = root / "scores"
        self.originals_dir = root / "originals"
        self.scores_dir.mkdir(parents=True, exist_ok=True)
        self.originals_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.index_path = root / "index.json"
        self.index = self._load_index()

    def _load_index(self) -> dict:
        try:
            data = json.loads(self.index_path.read_text())
            data.setdefault("scores", {})
            data.setdefault("collections", {"modified": None})
            return data
        except (FileNotFoundError, json.JSONDecodeError):
            return {"scores": {}, "collections": {"modified": None}}

    def _save_index(self) -> None:
        _atomic_write(self.index_path, json.dumps(self.index, indent=1, sort_keys=True).encode())

    # Listing

    def listing(self) -> dict:
        with self.lock:
            scores = [{"id": i, **entry} for i, entry in self.index["scores"].items()]
            return {"scores": scores, "collections": dict(self.index["collections"])}

    # Scores

    def get_score(self, score_id: str) -> bytes | None:
        with self.lock:
            entry = self.index["scores"].get(score_id)
            if not entry or entry.get("deleted"):
                return None
        try:
            return (self.scores_dir / f"{score_id}.json").read_bytes()
        except FileNotFoundError:
            return None

    def put_score(self, score_id: str, body: bytes, modified: float) -> None:
        """Stores a score. Raises ValueError if the body isn't a JSON object."""
        doc = json.loads(body)
        if not isinstance(doc, dict):
            raise ValueError("a score must be a JSON object")
        with self.lock:
            _atomic_write(self.scores_dir / f"{score_id}.json", body)
            entry = self.index["scores"].get(score_id, {})
            entry.update({
                "modified": modified,
                "deleted": False,
                "title": str(doc.get("title", ""))[:200],
                "composer": str(doc.get("composer", ""))[:200],
                "original": entry.get("original") if not entry.get("deleted") else None,
            })
            self.index["scores"][score_id] = entry
            self._save_index()

    def delete_score(self, score_id: str, modified: float) -> bool:
        with self.lock:
            entry = self.index["scores"].get(score_id)
            if entry is None:
                # Record the tombstone anyway: another device may still upload this id.
                entry = {"title": "", "composer": ""}
            entry.update({"modified": modified, "deleted": True, "original": None})
            self.index["scores"][score_id] = entry
            self._save_index()
        for path in (self.scores_dir / f"{score_id}.json", self.originals_dir / f"{score_id}.pdf"):
            path.unlink(missing_ok=True)
        return True

    # Originals

    def get_original(self, score_id: str) -> bytes | None:
        with self.lock:
            entry = self.index["scores"].get(score_id)
            if not entry or entry.get("deleted") or not entry.get("original"):
                return None
        try:
            return (self.originals_dir / f"{score_id}.pdf").read_bytes()
        except FileNotFoundError:
            return None

    def put_original(self, score_id: str, body: bytes) -> bool:
        """Stores the original PDF of an existing score. False if there is no such score."""
        if not body.startswith(b"%PDF"):
            raise ValueError("the original must be a PDF")
        with self.lock:
            entry = self.index["scores"].get(score_id)
            if not entry or entry.get("deleted"):
                return False
            _atomic_write(self.originals_dir / f"{score_id}.pdf", body)
            entry["original"] = "pdf"
            self._save_index()
        return True

    # Collections

    def get_collections(self) -> bytes | None:
        try:
            return (self.root / "collections.json").read_bytes()
        except FileNotFoundError:
            return None

    def put_collections(self, body: bytes, modified: float) -> None:
        doc = json.loads(body)
        if not isinstance(doc, dict):
            raise ValueError("collections must be a JSON object")
        with self.lock:
            _atomic_write(self.root / "collections.json", body)
            self.index["collections"] = {"modified": modified}
            self._save_index()
