#!/usr/bin/env python3
"""Music Reader server: reads sheet music with Audiveris, and keeps the user's score library.

The app uploads a PDF (or PNG/JPEG/TIFF scan), Audiveris transcribes it in the background, and the app
polls the job and downloads MusicXML. Standard library only, so the Docker image needs nothing beyond
Python and the Audiveris package.

API
  GET    /health                       -> {"status": "ok", "engine": "audiveris", "version": "..."}
  POST   /jobs                         body = the file bytes; header X-Filename: name.pdf  -> 202 {"id": ...}
  GET    /jobs/<id>                    -> {"id", "status": queued|running|done|failed, "error", "movements", "elapsed"}
  GET    /jobs/<id>/musicxml?movement=N  -> the uncompressed MusicXML of movement N (default 0)
  DELETE /jobs/<id>                    -> 204

Library (see library_store.py; writes carry "X-Modified: <unix seconds>")
  GET    /library                         -> {"scores": [{id, modified, deleted, title, composer, original}], "collections": {modified}}
  GET    /library/scores/<id>             -> the score's JSON
  PUT    /library/scores/<id>             body = score JSON -> 204
  DELETE /library/scores/<id>             -> 204 (leaves a tombstone)
  GET    /library/scores/<id>/original    -> the imported PDF
  PUT    /library/scores/<id>/original    body = PDF -> 204
  GET    /library/collections             -> the collections JSON document
  PUT    /library/collections             body = collections JSON -> 204

Environment
  OMR_PORT        port to listen on (8765)
  OMR_DATA        working directory for jobs (/data)
  OMR_TOKEN       if set, every request except /health needs "Authorization: Bearer <token>"
  AUDIVERIS_CMD   the Audiveris launcher (/opt/audiveris/bin/Audiveris)
  OMR_TIMEOUT     seconds before a transcription is abandoned (900)
  OMR_KEEP_HOURS  finished jobs are deleted after this many hours (24)
  OMR_FINGERINGS  1 to also recognise printed fingering digits (0). Off by default: on photos it mistakes
                  small marks (a down-bow) for fingers as often as it finds real ones.
"""

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import subprocess
import threading
import time
import uuid
import zipfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from xml.etree import ElementTree

from library_store import LibraryStore, valid_id

try:  # Pillow is optional: without it images go to Audiveris untouched.
    from PIL import Image, ImageOps
except ImportError:  # pragma: no cover
    Image = None

PORT = int(os.environ.get("OMR_PORT", "8765"))
DATA = Path(os.environ.get("OMR_DATA", "/data"))
TOKEN = os.environ.get("OMR_TOKEN") or None
AUDIVERIS = os.environ.get("AUDIVERIS_CMD", "/opt/audiveris/bin/Audiveris")
TIMEOUT = int(os.environ.get("OMR_TIMEOUT", "900"))
KEEP_HOURS = float(os.environ.get("OMR_KEEP_HOURS", "24"))
FINGERINGS = os.environ.get("OMR_FINGERINGS", "0") == "1"
MAX_UPLOAD = 60 * 1024 * 1024
MAX_SCORE = 20 * 1024 * 1024
ALLOWED = {".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff"}


class Job:
    def __init__(self, job_id: str, filename: str):
        self.id = job_id
        self.filename = filename
        self.status = "queued"
        self.error: str | None = None
        self.movements: list[Path] = []
        self.created = time.time()
        self.started: float | None = None
        self.finished: float | None = None

    @property
    def dir(self) -> Path:
        return DATA / "jobs" / self.id

    def to_json(self) -> dict:
        end = self.finished or time.time()
        return {
            "id": self.id,
            "filename": self.filename,
            "status": self.status,
            "error": self.error,
            "movements": len(self.movements),
            "elapsed": round(end - (self.started or end), 1),
        }


jobs: dict[str, Job] = {}
jobs_lock = threading.Lock()
work: "queue.Queue[Job]" = queue.Queue()


def safe_filename(name: str) -> str:
    base = Path(name).name or "score.pdf"
    stem, ext = os.path.splitext(base)
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._") or "score"
    return stem[:80] + ext.lower()


def extract_musicxml(path: Path) -> bytes:
    """Audiveris writes compressed .mxl (a zip); the app wants plain MusicXML."""
    if path.suffix.lower() != ".mxl":
        return path.read_bytes()
    with zipfile.ZipFile(path) as z:
        rootfile = None
        try:
            container = ElementTree.fromstring(z.read("META-INF/container.xml"))
            for el in container.iter():
                if el.tag.endswith("rootfile") and el.get("full-path"):
                    rootfile = el.get("full-path")
                    break
        except KeyError:
            pass
        if rootfile is None:
            rootfile = next(n for n in z.namelist() if n.endswith(".xml") and not n.startswith("META-INF/"))
        return z.read(rootfile)


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}


def prepare_image(source: Path) -> Path:
    """Photos of sheet music read much better as grayscale with the contrast stretched: colour casts,
    shadows and a grey page confuse binarisation. On a phone photo this took a piece from 15/16 bars
    right with 20 phantom marks to 16/16 with 6. Hard thresholding here is worse: Audiveris binarises
    adaptively and better than a global cut."""
    if Image is None or source.suffix.lower() not in IMAGE_SUFFIXES:
        return source
    with Image.open(source) as im:
        gray = ImageOps.autocontrast(ImageOps.exif_transpose(im).convert("L"), cutoff=1)
        prepared = source.with_name(source.stem + ".prepared.png")
        gray.save(prepared)
    return prepared


def movement_key(path: Path) -> tuple[int, str]:
    # "book.mvt2.mxl" sorts after "book.mvt1.mxl"; a single-movement "book.mxl" comes first.
    m = re.search(r"\.mvt(\d+)\.", path.name)
    return (int(m.group(1)) if m else 0, path.name)


def run_audiveris(job: Job) -> None:
    out = job.dir / "out"
    out.mkdir(parents=True, exist_ok=True)
    source = prepare_image(job.dir / job.filename)
    cmd = [AUDIVERIS, "-batch", "-export", "-output", str(out)]
    if FINGERINGS:
        cmd += ["-constant", "org.audiveris.omr.sheet.ProcessingSwitches.fingerings=true"]
    cmd += ["--", str(source)]
    log_path = job.dir / "audiveris.log"
    with open(log_path, "wb") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=TIMEOUT, check=False)
    found = sorted([p for p in out.rglob("*") if p.suffix.lower() in (".mxl", ".xml") and p.is_file()], key=movement_key)
    if not found:
        tail = log_path.read_text(errors="replace").strip().splitlines()[-8:]
        reason = "no music was recognised" if proc.returncode == 0 else f"Audiveris exited with code {proc.returncode}"
        raise RuntimeError(reason + (": " + " | ".join(tail) if tail else ""))
    job.movements = found


def worker() -> None:
    while True:
        job = work.get()
        job.status = "running"
        job.started = time.time()
        try:
            run_audiveris(job)
            job.status = "done"
        except subprocess.TimeoutExpired:
            job.status, job.error = "failed", f"transcription took longer than {TIMEOUT} s"
        except Exception as e:  # noqa: BLE001 - any failure is reported to the client
            job.status, job.error = "failed", str(e)[:1000]
        finally:
            job.finished = time.time()
            work.task_done()


def janitor() -> None:
    while True:
        time.sleep(600)
        cutoff = time.time() - KEEP_HOURS * 3600
        with jobs_lock:
            stale = [j for j in jobs.values() if j.finished and j.finished < cutoff]
            for j in stale:
                jobs.pop(j.id, None)
        for j in stale:
            shutil.rmtree(j.dir, ignore_errors=True)


def audiveris_version() -> str:
    try:
        r = subprocess.run([AUDIVERIS, "-version"], capture_output=True, text=True, timeout=60)
        # "- Version:      5.11.0"
        m = re.search(r"Version:?\s+(\d+\.\d+(?:\.\d+)?)", r.stdout + r.stderr, re.I)
        return m.group(1) if m else "unknown"
    except Exception:  # noqa: BLE001
        return "unavailable"


VERSION = "unknown"
library: LibraryStore | None = None


class Handler(BaseHTTPRequestHandler):
    server_version = "MusicReaderOMR/1.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def send_json(self, status: int, body: dict | None) -> None:
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorised(self) -> bool:
        if TOKEN is None:
            return True
        if self.headers.get("Authorization", "") == f"Bearer {TOKEN}":
            return True
        self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "missing or wrong token"})
        return False

    def read_body(self, limit: int) -> bytes | None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > limit:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length else HTTPStatus.BAD_REQUEST,
                           {"error": f"body must be between 1 byte and {limit // 1024 // 1024} MB"})
            return None
        chunks, remaining = [], length
        while remaining:
            chunk = self.rfile.read(min(remaining, 1 << 16))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def modified_header(self) -> float | None:
        try:
            return float(self.headers.get("X-Modified", ""))
        except ValueError:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "X-Modified (unix seconds) is required"})
            return None

    def send_bytes(self, data: bytes | None, content_type: str) -> None:
        if data is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def library_route(self, method: str, parts: list[str]) -> bool:
        """Handles /library…; False if the path isn't a library path."""
        if not parts or parts[0] != "library":
            return False
        assert library is not None
        rest = parts[1:]
        if rest and rest[0] == "scores" and len(rest) >= 2 and not valid_id(rest[1]):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "score ids are UUIDs"})
            return True
        try:
            if method == "GET" and rest == []:
                self.send_json(HTTPStatus.OK, library.listing())
            elif method == "GET" and rest == ["collections"]:
                self.send_bytes(library.get_collections(), "application/json")
            elif method == "PUT" and rest == ["collections"]:
                modified = self.modified_header()
                body = self.read_body(MAX_SCORE) if modified is not None else None
                if body is not None:
                    library.put_collections(body, modified)
                    self.send_json(HTTPStatus.NO_CONTENT, None)
            elif len(rest) == 2 and rest[0] == "scores":
                if method == "GET":
                    self.send_bytes(library.get_score(rest[1]), "application/json")
                elif method == "PUT":
                    modified = self.modified_header()
                    body = self.read_body(MAX_SCORE) if modified is not None else None
                    if body is not None:
                        library.put_score(rest[1], body, modified)
                        self.send_json(HTTPStatus.NO_CONTENT, None)
                elif method == "DELETE":
                    modified = self.modified_header()
                    if modified is not None:
                        library.delete_score(rest[1], modified)
                        self.send_json(HTTPStatus.NO_CONTENT, None)
                else:
                    self.send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "method not allowed"})
            elif len(rest) == 3 and rest[0] == "scores" and rest[2] == "original":
                if method == "GET":
                    self.send_bytes(library.get_original(rest[1]), "application/pdf")
                elif method == "PUT":
                    body = self.read_body(MAX_UPLOAD)
                    if body is not None:
                        if library.put_original(rest[1], body):
                            self.send_json(HTTPStatus.NO_CONTENT, None)
                        else:
                            self.send_json(HTTPStatus.NOT_FOUND, {"error": "upload the score first"})
                else:
                    self.send_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "method not allowed"})
            else:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except (ValueError, json.JSONDecodeError) as e:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(e)[:300]})
        return True

    def job_from_path(self, parts: list[str]) -> Job | None:
        with jobs_lock:
            job = jobs.get(parts[1]) if len(parts) > 1 else None
        if job is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "no such job"})
        return job

    def do_GET(self) -> None:
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if parts == ["health"]:
            self.send_json(HTTPStatus.OK, {"status": "ok", "engine": "audiveris", "version": VERSION,
                                           "auth": TOKEN is not None, "queued": work.qsize(), "library": True})
            return
        if not self.authorised():
            return
        if self.library_route("GET", parts):
            return
        if len(parts) == 2 and parts[0] == "jobs":
            if job := self.job_from_path(parts):
                self.send_json(HTTPStatus.OK, job.to_json())
            return
        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "musicxml":
            job = self.job_from_path(parts)
            if job is None:
                return
            if job.status != "done":
                self.send_json(HTTPStatus.CONFLICT, {"error": f"job is {job.status}"})
                return
            index = int(parse_qs(url.query).get("movement", ["0"])[0] or 0)
            if not 0 <= index < len(job.movements):
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "no such movement"})
                return
            data = extract_musicxml(job.movements[index])
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/vnd.recordare.musicxml+xml")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if parts != ["jobs"]:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if not self.authorised():
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_UPLOAD:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length else HTTPStatus.BAD_REQUEST,
                           {"error": f"upload must be between 1 byte and {MAX_UPLOAD // 1024 // 1024} MB"})
            return
        filename = safe_filename(self.headers.get("X-Filename", "score.pdf"))
        if Path(filename).suffix not in ALLOWED:
            self.send_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": f"send one of {sorted(ALLOWED)}"})
            return
        job = Job(uuid.uuid4().hex, filename)
        job.dir.mkdir(parents=True, exist_ok=True)
        with open(job.dir / filename, "wb") as f:
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(remaining, 1 << 16))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        with jobs_lock:
            jobs[job.id] = job
        work.put(job)
        self.send_json(HTTPStatus.ACCEPTED, job.to_json())

    def do_PUT(self) -> None:
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not self.authorised():
            return
        if not self.library_route("PUT", parts):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_DELETE(self) -> None:
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if parts[:1] == ["library"]:
            if self.authorised():
                self.library_route("DELETE", parts)
            return
        if len(parts) != 2 or parts[0] != "jobs":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if not self.authorised():
            return
        with jobs_lock:
            job = jobs.pop(parts[1], None)
        if job is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "no such job"})
            return
        # A running job finishes in the background; its files go when the worker is done with them.
        if job.status != "running":
            shutil.rmtree(job.dir, ignore_errors=True)
        self.send_json(HTTPStatus.NO_CONTENT, None)


def main() -> None:
    global VERSION, library
    (DATA / "jobs").mkdir(parents=True, exist_ok=True)
    library = LibraryStore(DATA / "library")
    VERSION = audiveris_version()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=janitor, daemon=True).start()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Music Reader OMR server on :{PORT} (Audiveris {VERSION}, auth {'on' if TOKEN else 'off'})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
