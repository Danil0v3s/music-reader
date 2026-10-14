#!/usr/bin/env python3
"""Music Reader server: reads sheet music with Audiveris, and keeps each user's score library.

The app uploads a PDF (or PNG/JPEG/TIFF scan), Audiveris transcribes it in the background, and the app
polls the job and downloads MusicXML. Standard library only (plus Pillow for preparing photos), so the
Docker image needs nothing beyond Python and the Audiveris package.

This file is recognition and the program's entry point; the HTTP API is api.py, accounts accounts.py,
the libraries library_store.py, the database db.py. Every route except /health and signing in needs a
session ("Authorization: Bearer <access token>"); see api.py for the routes.

Environment
  OMR_PORT              port to listen on (8765)
  OMR_DATA              data directory: database, originals, recognition jobs (/data)
  OMR_PUBLIC_URL        the address people reach the server at, for links in emails (http://localhost:8765)
  OMR_APPLE_AUDIENCE    Sign in with Apple: the app's bundle id (br.com.firstsoft.musicreader); empty disables
  OMR_APPLE_TEAM_ID, OMR_APPLE_KEY_ID, OMR_APPLE_PRIVATE_KEY(_FILE)   the Sign in with Apple key, to revoke a
                        deleted account's Apple sign-in as the App Store requires (see apple_tokens.py)
  OMR_GOOGLE_CLIENT_IDS Google Sign-In: the app's OAuth client id(s), comma-separated; empty disables
  OMR_SMTP_HOST/PORT/USER/PASSWORD, OMR_MAIL_FROM   sending account emails (see mailer.py; without, they're logged)
  AUDIVERIS_CMD         the Audiveris launcher (/opt/audiveris/bin/Audiveris)
  OMR_TIMEOUT           seconds before a transcription is abandoned (900)
  OMR_KEEP_HOURS        finished jobs' files are deleted after this many hours (24)
  OMR_FINGERINGS        1 to also recognise printed fingering digits (0). Off by default: on photos it mistakes
                        small marks (a down-bow) for fingers as often as it finds real ones.

Commands
  python3 omr_server.py                                   run the server
  python3 omr_server.py import-library <email> [folder]   move a library from before accounts (<data>/library)
                                                          into the account that signs in with <email>
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
from fractions import Fraction
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from xml.etree import ElementTree

from db import Database

try:  # Pillow is optional: without it images go to Audiveris untouched.
    from PIL import Image, ImageOps
except ImportError:  # pragma: no cover
    Image = None

PORT = int(os.environ.get("OMR_PORT", "8765"))
DATA = Path(os.environ.get("OMR_DATA", "/data"))
AUDIVERIS = os.environ.get("AUDIVERIS_CMD", "/opt/audiveris/bin/Audiveris")
TIMEOUT = int(os.environ.get("OMR_TIMEOUT", "900"))
KEEP_HOURS = float(os.environ.get("OMR_KEEP_HOURS", "24"))
FINGERINGS = os.environ.get("OMR_FINGERINGS", "0") == "1"
MAX_UPLOAD = 60 * 1024 * 1024
MAX_SCORE = 20 * 1024 * 1024
ALLOWED = {".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff"}


class Job:
    def __init__(self, job_id: str, filename: str, user_id: str = "", device_id: str | None = None):
        self.id = job_id
        self.filename = filename
        self.user_id = user_id
        self.device_id = device_id
        self.status = "queued"
        self.error: str | None = None
        self.movements: list[Path] = []
        self.created = time.time()
        self.started: float | None = None
        self.finished: float | None = None
        # How an image was prepared: the measured staff spacing and the scale applied.
        self.prepared: dict = {}

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
            **({"prepared": self.prepared} if self.prepared else {}),
        }


jobs: dict[str, Job] = {}
jobs_lock = threading.Lock()
work: "queue.Queue[Job]" = queue.Queue()
database: Database | None = None


def count_pages(path: Path) -> int:
    """Pages in an upload: 1 for an image; for a PDF, its page objects (good enough to count scans by page)."""
    if path.suffix.lower() != ".pdf":
        return 1
    data = path.read_bytes()
    return max(1, len(re.findall(rb"/Type\s*/Page(?![s\w])", data)))


def log_job(job: Job, **fields) -> None:
    """Keeps the scan log (db.scan_jobs) in step with a job: who scanned, from which device, how many pages."""
    if database is None:
        return
    with database.tx() as c:
        if fields.pop("create", False):
            path = job.dir / job.filename
            c.execute("""INSERT INTO scan_jobs (id, user_id, device_id, filename, kind, bytes, pages, status, created)
                         VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?)""",
                      (job.id, job.user_id or None, job.device_id, job.filename, "pdf" if path.suffix.lower() == ".pdf" else "image",
                       path.stat().st_size, count_pages(path), job.created))
        else:
            c.execute("UPDATE scan_jobs SET status = ?, error = ?, movements = ?, started = ?, finished = ? WHERE id = ?",
                      (job.status, job.error, len(job.movements), job.started, job.finished, job.id))


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


# Audiveris measures everything in "interlines", the distance from one staff line to the next. It reads best
# at about 20 px (a 300 dpi scan) and fails outright below roughly 10 ("Error in export"): an 800 px wide
# screenshot of a page has about 7. Images are enlarged to reach the target, measured on the image itself.
TARGET_INTERLINE = 20
MIN_INTERLINE = 15        # below this, enlarge
MAX_SCALE = 4
MIN_WIDTH = 1600          # when no staff can be measured: pixels across the page, roughly 150 dpi for A4


def estimate_interline(gray: "Image.Image") -> float | None:
    """The staff line spacing in pixels, or None when there's no clear staff. Like Audiveris's own scale
    check: down sampled columns, every thin dark run followed by a light run and another dark run is a
    candidate line + space; the staff lines make the most common combined length stand out."""
    w, h = gray.size
    if w < 20 or h < 20:
        return None
    px = gray.tobytes()
    counts: dict[int, int] = {}
    for x in range(w // 20, w - w // 20, max(1, w // 150)):
        runs: list[tuple[bool, int]] = []          # (dark, length) down the column
        for y in range(h):
            dark = px[y * w + x] < 128
            if runs and runs[-1][0] == dark:
                runs[-1] = (dark, runs[-1][1] + 1)
            else:
                runs.append((dark, 1))
        for (d1, black), (_, white), (d3, _) in zip(runs, runs[1:], runs[2:]):
            if d1 and d3 and black <= max(3, h // 400) and 2 <= white <= 100:
                counts[black + white] = counts.get(black + white, 0) + 1
    if not counts:
        return None
    # Lines are drawn a pixel thicker or thinner here and there, so a spacing and its neighbours count together.
    best = max(counts, key=lambda n: counts.get(n - 1, 0) + 2 * counts[n] + counts.get(n + 1, 0))
    support = counts.get(best - 1, 0) + counts[best] + counts.get(best + 1, 0)
    if support < 20:
        return None
    return sum(n * counts.get(n, 0) for n in (best - 1, best, best + 1)) / support


def prepare_image(source: Path, boost: float = 1) -> tuple[Path, dict]:
    """Photos of sheet music read much better as grayscale with the contrast stretched: colour casts,
    shadows and a grey page confuse binarisation. On a phone photo this took a piece from 15/16 bars
    right with 20 phantom marks to 16/16 with 6. Hard thresholding here is worse: Audiveris binarises
    adaptively and better than a global cut.

    Small images are enlarged so the staff spacing reaches TARGET_INTERLINE; `boost` enlarges further
    (a retry after a failed read). Returns the prepared file and what was done to it."""
    if Image is None or source.suffix.lower() not in IMAGE_SUFFIXES:
        return source, {}
    with Image.open(source) as im:
        gray = ImageOps.autocontrast(ImageOps.exif_transpose(im).convert("L"), cutoff=1)
    interline = estimate_interline(gray)
    if interline is not None:
        scale = TARGET_INTERLINE / interline if interline < MIN_INTERLINE else 1
    else:
        scale = MIN_WIDTH / gray.width if gray.width < MIN_WIDTH else 1
    scale = min(MAX_SCALE, scale * boost)
    if scale > 1.05:
        gray = gray.resize((round(gray.width * scale), round(gray.height * scale)), Image.Resampling.LANCZOS)
    else:
        scale = 1
    prepared = source.with_name(source.stem + ".prepared.png")
    gray.save(prepared)
    return prepared, {"interline": round(interline, 1) if interline else None, "scale": round(scale, 2)}


def movement_key(path: Path) -> tuple[int, str]:
    # "book.mvt2.mxl" sorts after "book.mvt1.mxl"; a single-movement "book.mxl" comes first.
    m = re.search(r"\.mvt(\d+)\.", path.name)
    return (int(m.group(1)) if m else 0, path.name)


def reading_quality(movements: list[Path]) -> tuple[int, int, int]:
    """How good a reading looks, to choose between readings: bars that add up exactly to their time
    signature first (a missed note leaves a bar short, a speck read as a note overfills it), then bars
    found, then notes. When no time signature was read (a missed C sign), the most common bar length
    stands in for it."""
    complete = bars = notes = 0
    for path in movements:
        try:
            root = ElementTree.fromstring(extract_musicxml(path))
        except (ElementTree.ParseError, zipfile.BadZipFile, KeyError, StopIteration):
            continue
        part = root.find("part")
        if part is None:
            continue
        divisions, expected = 1, None
        unchecked: list[Fraction] = []
        for measure in part.findall("measure"):
            bars += 1
            attrs = measure.find("attributes")
            if attrs is not None:
                divisions = int(attrs.findtext("divisions") or divisions)
                beats, beat_type = attrs.findtext("time/beats"), attrs.findtext("time/beat-type")
                if beats and beat_type:
                    expected = Fraction(int(beats), int(beat_type))
            filled = Fraction(0)
            for note in measure.findall("note"):
                notes += 1
                voice = note.findtext("voice") or "1"
                if voice == "1" and note.find("chord") is None and note.find("grace") is None:
                    filled += Fraction(int(note.findtext("duration") or 0), 4 * divisions)
            if expected is None:
                unchecked.append(filled)
            elif filled == expected:
                complete += 1
        if unchecked:
            usual = max(set(unchecked), key=unchecked.count)
            complete += sum(1 for f in unchecked if f == usual and f > 0)
    return complete, bars, notes


def read_once(job: Job, boost: float, attempt: int) -> tuple[list[Path], dict, int]:
    source, prepared = prepare_image(job.dir / job.filename, boost)
    out = job.dir / f"out{attempt}"
    out.mkdir(parents=True, exist_ok=True)
    cmd = [AUDIVERIS, "-batch", "-export", "-output", str(out)]
    if FINGERINGS:
        cmd += ["-constant", "org.audiveris.omr.sheet.ProcessingSwitches.fingerings=true"]
    cmd += ["--", str(source)]
    with open(job.dir / "audiveris.log", "wb") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=TIMEOUT, check=False)
    found = sorted([p for p in out.rglob("*") if p.suffix.lower() in (".mxl", ".xml") and p.is_file()], key=movement_key)
    return found, prepared, proc.returncode


# Readings of an enlarged image, as boosts over the measured scale. Audiveris is touchy about exact sizes:
# a page that reads 12/12 bars at 2x, 2.5x and 3x read 2 bars at 2.43x. So an enlarged image is read at two
# sizes and the better reading wins (see reading_quality); a failed reading is tried again at twice the size.
SECOND_READING = 1.25
FAILED_RETRY = 2


def run_audiveris(job: Job) -> None:
    found, prepared, code = read_once(job, 1, 0)
    readings = [(found, prepared)]
    if prepared and prepared["scale"] > 1 and prepared["scale"] < MAX_SCALE:
        readings.append(read_once(job, SECOND_READING, 1)[:2])
    if prepared and not any(f for f, _ in readings) and prepared["scale"] * FAILED_RETRY <= MAX_SCALE * 1.001:
        found, retry, code = read_once(job, FAILED_RETRY, len(readings))
        readings.append((found, {**retry, "retried": True}))
    sizes = [reading_quality(f) if f else (-1, -1, -1) for f, _ in readings]
    best = max(range(len(readings)), key=lambda i: (sizes[i], -i))
    found, job.prepared = readings[best]
    if len(readings) > 1:
        job.prepared = {**job.prepared, "readings": [{"scale": p.get("scale"), "complete": c, "bars": b, "notes": n}
                                                     for (_, p), (c, b, n) in zip(readings, sizes)]}
    if not found:
        tail = (job.dir / "audiveris.log").read_text(errors="replace").strip().splitlines()[-8:]
        reason = "no music was recognised" if code == 0 else f"Audiveris exited with code {code}"
        raise RuntimeError(reason + (": " + " | ".join(tail) if tail else ""))
    job.movements = found


def worker() -> None:
    while True:
        job = work.get()
        job.status = "running"
        job.started = time.time()
        log_job(job)
        try:
            run_audiveris(job)
            job.status = "done"
        except subprocess.TimeoutExpired:
            job.status, job.error = "failed", f"transcription took longer than {TIMEOUT} s"
        except Exception as e:  # noqa: BLE001 - any failure is reported to the client
            job.status, job.error = "failed", str(e)[:1000]
        finally:
            job.finished = time.time()
            log_job(job)
            work.task_done()


accounts_service = None


def janitor() -> None:
    last_guest_sweep = 0.0
    while True:
        time.sleep(600)
        if accounts_service is not None and time.time() - last_guest_sweep > 86400:
            last_guest_sweep = time.time()
            removed = accounts_service.delete_stale_guests()
            if removed:
                print(f"Deleted {removed} guest account(s) unused for a year.", flush=True)
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


def open_services(data: Path):
    """The database, libraries and accounts over a data directory."""
    import accounts as accounts_module
    from library_store import LibraryStore
    db = Database(data / "music-reader.sqlite3")
    library = LibraryStore(db, data / "originals")
    from apple_tokens import AppleClient
    apple = AppleClient.from_environment(os.environ.get("OMR_APPLE_AUDIENCE", "br.com.firstsoft.musicreader").split(",")[0])
    acc = accounts_module.Accounts(db, library, os.environ.get("OMR_PUBLIC_URL", f"http://localhost:{PORT}"), apple)
    return db, library, acc


def main() -> None:
    import sys
    global VERSION, database, accounts_service
    # Run as a script this module is __main__; api.py imports it by name and must get this same module
    # (one job queue), not a second copy.
    sys.modules.setdefault("omr_server", sys.modules[__name__])
    if len(sys.argv) >= 3 and sys.argv[1] == "import-library":
        _, library, acc = open_services(DATA)
        email = sys.argv[2].strip().lower()
        row = library.db.one("SELECT user_id FROM identities WHERE email = ? OR subject = ?", (email, email))
        if row is None:
            sys.exit(f"No account signs in with {email}. Sign in with it in the app first.")
        folder = Path(sys.argv[3]) if len(sys.argv) > 3 else DATA / "library"
        print(f"Imported {library.import_legacy(folder, row['user_id'])} scores into {email}'s library.")
        return
    import api
    (DATA / "jobs").mkdir(parents=True, exist_ok=True)
    database, library, acc = open_services(DATA)
    accounts_service = acc
    api.configure(database, library, acc)
    VERSION = audiveris_version()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=janitor, daemon=True).start()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), api.Handler)
    print(f"Music Reader server on :{PORT} (Audiveris {VERSION}; sign-in: {', '.join(api.providers())})", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
