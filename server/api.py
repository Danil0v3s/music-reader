"""The HTTP API.

Every request may carry X-Device (the app's install id, from its Keychain), X-Platform and X-App-Version.
Requests that act for a user carry "Authorization: Bearer <access token>". Errors are JSON:
{"error": "<message for people>", "code": "<for the app>"}.

Web pages
  GET    /privacy, /terms                 the privacy policy and terms (server/legal/)

Health
  GET    /health                          -> {status, engine, version, queued, accounts: true, providers: [...]}

Signing in (each returns {accessToken, refreshToken, expiresIn, user, mergedScores?}). Sent with a guest's
session, they upgrade that guest instead: the method is attached to the guest's account, or, if it
already belongs to another account, the guest's library moves there.
  POST   /auth/guest                      {}                                   a new guest account for this device
  POST   /auth/apple                      {identityToken, nonce?, name?, authorizationCode?}
  POST   /auth/google                     {idToken}
  POST   /auth/email/signup               {email, password, name?}
  POST   /auth/email/signin               {email, password}
  POST   /auth/email/reset-request        {email}                              -> 204, sends a reset link if the account exists
  GET    /auth/email/verify?token=        (the link in the email)              -> a web page
  GET    /auth/email/reset?token=         (the link in the email)              -> a web page with a form
  POST   /auth/email/reset                {token, password} (JSON or form)     -> 204 / a web page
  POST   /auth/refresh                    {refreshToken}                       -> new tokens (the old ones stop working)
  POST   /auth/signout                    {everywhere?: bool}                  -> 204

The account
  GET    /me                              -> {id, displayName, email, emailVerified, isGuest, providers, created}
  POST   /me/link/apple | /me/link/google  {identityToken|idToken, …}           -> the account, with the method added
  DELETE /me                              -> 204: the account and everything in it is deleted

The library (library_store.py; writes carry "X-Modified: <unix seconds>")
  GET    /library                         -> {"scores": [{id, modified, deleted, title, composer, original}], "collections": {modified}}
  GET    /library/scores/<id>             -> the score's JSON
  PUT    /library/scores/<id>             body = score JSON -> 204
  DELETE /library/scores/<id>             -> 204 (leaves a tombstone)
  GET    /library/scores/<id>/original    -> the imported PDF
  PUT    /library/scores/<id>/original    body = PDF -> 204
  GET    /library/collections             -> the collections JSON document
  PUT    /library/collections             body = collections JSON -> 204

Recognition (a user's jobs are visible only to them)
  POST   /jobs                            body = the file bytes; header X-Filename: name.pdf  -> 202 {"id": ...}
  GET    /jobs/<id>                       -> {"id", "status": queued|running|done|failed, "error", "movements", "elapsed", "prepared",
                                              "ahead": recognitions before it, while queued}
  (429 when the user already has OMR_JOBS_PER_USER waiting; 413 for a PDF over OMR_MAX_PAGES pages)
  GET    /jobs/<id>/musicxml?movement=N   -> the uncompressed MusicXML of movement N (default 0)
  DELETE /jobs/<id>                       -> 204
"""

from __future__ import annotations

import html
import json
import os
import shutil
import threading
import time
import uuid
from collections import defaultdict, deque
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import omr_server as omr
from accounts import AccountError, Accounts, Auth
from db import Database
from idtokens import APPLE, GOOGLE, TokenError, Verifier
from library_store import LibraryStore, valid_id

TRUST_PROXY = os.environ.get("OMR_TRUST_PROXY", "0") == "1"
LEGAL = Path(__file__).resolve().parent / "legal"
db: Database | None = None
library: LibraryStore | None = None
accounts: Accounts | None = None
apple = Verifier(APPLE, {a for a in os.environ.get("OMR_APPLE_AUDIENCE", "br.com.firstsoft.musicreader").split(",") if a})
google = Verifier(GOOGLE, {a.strip() for a in os.environ.get("OMR_GOOGLE_CLIENT_IDS", "").split(",") if a.strip()})


def configure(database: Database, lib: LibraryStore, acc: Accounts) -> None:
    global db, library, accounts
    db, library, accounts = database, lib, acc


def providers() -> list[str]:
    return (["apple"] if apple.audiences else []) + (["google"] if google.audiences else []) + ["email", "guest"]


class RateLimiter:
    """At most `limit` requests per `window` seconds for each key (an IP and a kind of request)."""

    def __init__(self, limit: int, window: float):
        self.limit, self.window = limit, window
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self.lock:
            q = self.hits[key]
            while q and q[0] < now - self.window:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            return True


# Sign-in attempts and new accounts per IP: generous for a family behind one router, useless for guessing.
auth_limiter = RateLimiter(30, 600)
signup_limiter = RateLimiter(10, 3600)


class Handler(BaseHTTPRequestHandler):
    server_version = "MusicReader/2.0"

    def log_message(self, fmt: str, *args) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    # Responses

    def send_json(self, status: int, body: dict | None) -> None:
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, status: int, message: str, code: str = "invalid") -> None:
        self.send_json(status, {"error": message, "code": code})

    def send_bytes(self, data: bytes | None, content_type: str) -> None:
        if data is None:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_page(self, title: str, body: str, status: int = 200) -> None:
        page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · Music Reader</title><style>
body{{font:17px -apple-system,system-ui,sans-serif;max-width:28rem;margin:3rem auto;padding:0 1rem;color:#222;background:#faf7f0}}
h1{{font-family:Georgia,serif;font-weight:600}} input{{font:inherit;width:100%;padding:.6rem;margin:.3rem 0 1rem;box-sizing:border-box}}
button{{font:inherit;padding:.6rem 1.2rem;background:#a0522d;color:#fff;border:0;border-radius:2rem}}
@media(prefers-color-scheme:dark){{body{{background:#1c1b19;color:#eee}}}}</style></head>
<body><h1>{html.escape(title)}</h1>{body}</body></html>""".encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    # Requests

    def read_body(self, limit: int) -> bytes | None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > limit:
            self.fail(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length else HTTPStatus.BAD_REQUEST,
                      f"body must be between 1 byte and {max(1, limit // 1024 // 1024)} MB", "body_size")
            return None
        chunks, remaining = [], length
        while remaining:
            chunk = self.rfile.read(min(remaining, 1 << 16))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def read_json(self) -> dict | None:
        """A small JSON object body ({} when there's none)."""
        if int(self.headers.get("Content-Length") or 0) == 0:
            return {}
        body = self.read_body(64 * 1024)
        if body is None:
            return None
        try:
            if "application/x-www-form-urlencoded" in self.headers.get("Content-Type", ""):
                return {k: v[0] for k, v in parse_qs(body.decode()).items()}
            doc = json.loads(body)
            if isinstance(doc, dict):
                return doc
        except (ValueError, UnicodeDecodeError):
            pass
        self.fail(HTTPStatus.BAD_REQUEST, "send a JSON object", "bad_json")
        return None

    def modified_header(self) -> float | None:
        try:
            return float(self.headers.get("X-Modified", ""))
        except ValueError:
            self.fail(HTTPStatus.BAD_REQUEST, "X-Modified (unix seconds) is required", "modified_missing")
            return None

    def client_ip(self) -> str:
        # Behind the reverse proxy (Caddy) the client's address is in X-Forwarded-For. Only then: otherwise
        # anyone could send the header and dodge the rate limits.
        forwarded = self.headers.get("X-Forwarded-For", "") if TRUST_PROXY else ""
        return forwarded.split(",")[-1].strip() if forwarded else self.client_address[0]

    def device(self) -> str | None:
        return accounts.register_device(self.headers.get("X-Device"), self.headers.get("X-Platform", ""),
                                        self.headers.get("X-App-Version", ""))

    def session(self) -> Auth | None:
        header = self.headers.get("Authorization", "")
        return accounts.authenticate(header[7:].strip() if header.startswith("Bearer ") else None)

    def require_session(self) -> Auth | None:
        auth = self.session()
        if auth is None:
            self.fail(HTTPStatus.UNAUTHORIZED, "Sign in to continue.", "unauthorised")
        return auth

    # Routing

    def route(self, method: str) -> None:
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)
        try:
            if parts == ["health"] and method == "GET":
                self.send_json(HTTPStatus.OK, {"status": "ok", "engine": "audiveris", "version": omr.VERSION,
                                               "queued": omr.work.qsize(), "accounts": True, "auth": True,
                                               "providers": providers(), "library": True})
            elif method == "GET" and parts in (["privacy"], ["terms"]):
                self.send_legal(parts[0])
            elif parts[:1] == ["auth"]:
                self.auth_route(method, parts[1:], query)
            elif parts[:1] == ["me"]:
                self.me_route(method, parts[1:])
            elif parts[:1] == ["library"]:
                if auth := self.require_session():
                    self.library_route(method, parts[1:], auth)
            elif parts[:1] == ["jobs"]:
                if auth := self.require_session():
                    self.jobs_route(method, parts[1:], query, auth)
            else:
                self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")
        except AccountError as e:
            self.fail(e.status, str(e), e.code)
        except TokenError as e:
            self.fail(HTTPStatus.UNAUTHORIZED, f"Couldn't verify the sign-in: {e}.", "token_invalid")
        except (ValueError, json.JSONDecodeError) as e:
            self.fail(HTTPStatus.BAD_REQUEST, str(e)[:300], "invalid")

    do_GET = lambda self: self.route("GET")  # noqa: E731
    do_POST = lambda self: self.route("POST")  # noqa: E731
    do_PUT = lambda self: self.route("PUT")  # noqa: E731
    do_DELETE = lambda self: self.route("DELETE")  # noqa: E731

    def send_legal(self, name: str) -> None:
        try:
            body = (LEGAL / f"{name}.html").read_text()
        except FileNotFoundError:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")
            return
        title = "Privacy Policy" if name == "privacy" else "Terms of Use"
        self.send_page(title, body)

    # /auth

    def auth_route(self, method: str, rest: list[str], query: dict) -> None:
        if method == "GET" and rest == ["email", "verify"]:
            try:
                accounts.verify_email(query.get("token", [""])[0])
                self.send_page("Email confirmed", "<p>Thanks. You can go back to Music Reader.</p>")
            except AccountError as e:
                self.send_page("Link expired", f"<p>{html.escape(str(e))} Ask the app to send a new one.</p>", 400)
            return
        if method == "GET" and rest == ["email", "reset"]:
            token = html.escape(query.get("token", [""])[0], quote=True)
            self.send_page("Choose a new password", f"""<form method="post" action="/auth/email/reset">
<input type="hidden" name="token" value="{token}"><label>New password (at least 8 characters)
<input type="password" name="password" minlength="8" required autocomplete="new-password"></label>
<button type="submit">Save password</button></form>""")
            return
        if method != "POST":
            self.fail(HTTPStatus.METHOD_NOT_ALLOWED, "method not allowed", "method")
            return
        kind = "/".join(rest)
        if kind in ("guest", "email/signup") and not signup_limiter.allow(self.client_ip()):
            self.fail(HTTPStatus.TOO_MANY_REQUESTS, "Too many new accounts from this network. Try again later.", "rate_limited")
            return
        if not auth_limiter.allow(f"{self.client_ip()}:{kind}"):
            self.fail(HTTPStatus.TOO_MANY_REQUESTS, "Too many attempts. Wait a few minutes and try again.", "rate_limited")
            return
        body = self.read_json()
        if body is None:
            return
        current = self.session()
        if kind == "guest":
            self.send_json(HTTPStatus.OK, accounts.create_guest(self.device()))
        elif kind == "apple":
            claims = apple.verify(str(body.get("identityToken", "")), nonce=body.get("nonce"))
            self.send_json(HTTPStatus.OK, accounts.sign_in_with_provider("apple", claims, self.device(), current,
                                                                         name=str(body.get("name", "")),
                                                                         authorization_code=str(body.get("authorizationCode", ""))))
        elif kind == "google":
            claims = google.verify(str(body.get("idToken", "")))
            self.send_json(HTTPStatus.OK, accounts.sign_in_with_provider("google", claims, self.device(), current))
        elif kind == "email/signup":
            self.send_json(HTTPStatus.OK, accounts.email_sign_up(str(body.get("email", "")), str(body.get("password", "")),
                                                                 str(body.get("name", "")), self.device(), current))
        elif kind == "email/signin":
            self.send_json(HTTPStatus.OK, accounts.email_sign_in(str(body.get("email", "")), str(body.get("password", "")),
                                                                 self.device(), current))
        elif kind == "email/reset-request":
            accounts.request_password_reset(str(body.get("email", "")))
            self.send_json(HTTPStatus.NO_CONTENT, None)
        elif kind == "email/reset":
            form = "application/x-www-form-urlencoded" in self.headers.get("Content-Type", "")
            try:
                accounts.reset_password(str(body.get("token", "")), str(body.get("password", "")))
            except AccountError as e:
                if not form:
                    raise
                self.send_page("Couldn't change the password", f"<p>{html.escape(str(e))}</p>", 400)
                return
            if form:
                self.send_page("Password changed", "<p>Sign in to Music Reader with your new password.</p>")
            else:
                self.send_json(HTTPStatus.NO_CONTENT, None)
        elif kind == "refresh":
            self.send_json(HTTPStatus.OK, accounts.refresh(str(body.get("refreshToken", "")), self.device()))
        elif kind == "signout":
            if current:
                accounts.sign_out(current, everywhere=bool(body.get("everywhere")))
            self.send_json(HTTPStatus.NO_CONTENT, None)
        else:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")

    # /me

    def me_route(self, method: str, rest: list[str]) -> None:
        auth = self.require_session()
        if auth is None:
            return
        if method == "GET" and rest == []:
            self.send_json(HTTPStatus.OK, accounts.user_json(auth.user_id))
        elif method == "DELETE" and rest == []:
            accounts.delete_user(auth.user_id)
            self.send_json(HTTPStatus.NO_CONTENT, None)
        elif method == "POST" and len(rest) == 2 and rest[0] == "link" and rest[1] in ("apple", "google"):
            body = self.read_json()
            if body is None:
                return
            claims = (apple.verify(str(body.get("identityToken", "")), nonce=body.get("nonce")) if rest[1] == "apple"
                      else google.verify(str(body.get("idToken", ""))))
            self.send_json(HTTPStatus.OK, accounts.link_provider(auth, rest[1], claims))
        else:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")

    # /library

    def library_route(self, method: str, rest: list[str], auth: Auth) -> None:
        user = auth.user_id
        if rest and rest[0] == "scores" and len(rest) >= 2 and not valid_id(rest[1]):
            self.fail(HTTPStatus.BAD_REQUEST, "score ids are UUIDs", "bad_id")
            return
        if method == "GET" and rest == []:
            self.send_json(HTTPStatus.OK, library.listing(user))
        elif method == "GET" and rest == ["collections"]:
            self.send_bytes(library.get_collections(user), "application/json")
        elif method == "PUT" and rest == ["collections"]:
            modified = self.modified_header()
            body = self.read_body(omr.MAX_SCORE) if modified is not None else None
            if body is not None:
                library.put_collections(user, body, modified)
                self.send_json(HTTPStatus.NO_CONTENT, None)
        elif len(rest) == 2 and rest[0] == "scores":
            if method == "GET":
                self.send_bytes(library.get_score(user, rest[1]), "application/json")
            elif method == "PUT":
                modified = self.modified_header()
                body = self.read_body(omr.MAX_SCORE) if modified is not None else None
                if body is not None:
                    library.put_score(user, rest[1], body, modified)
                    self.send_json(HTTPStatus.NO_CONTENT, None)
            elif method == "DELETE":
                modified = self.modified_header()
                if modified is not None:
                    library.delete_score(user, rest[1], modified)
                    self.send_json(HTTPStatus.NO_CONTENT, None)
            else:
                self.fail(HTTPStatus.METHOD_NOT_ALLOWED, "method not allowed", "method")
        elif len(rest) == 3 and rest[0] == "scores" and rest[2] == "original":
            if method == "GET":
                self.send_bytes(library.get_original(user, rest[1]), "application/pdf")
            elif method == "PUT":
                body = self.read_body(omr.MAX_UPLOAD)
                if body is not None:
                    if library.put_original(user, rest[1], body):
                        self.send_json(HTTPStatus.NO_CONTENT, None)
                    else:
                        self.fail(HTTPStatus.NOT_FOUND, "upload the score first", "not_found")
            else:
                self.fail(HTTPStatus.METHOD_NOT_ALLOWED, "method not allowed", "method")
        else:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")

    # /jobs

    def own_job(self, job_id: str, auth: Auth) -> omr.Job | None:
        with omr.jobs_lock:
            job = omr.jobs.get(job_id)
        if job is None or job.user_id != auth.user_id:
            self.fail(HTTPStatus.NOT_FOUND, "no such job", "not_found")
            return None
        return job

    def jobs_route(self, method: str, rest: list[str], query: dict, auth: Auth) -> None:
        if method == "POST" and rest == []:
            self.create_job(auth)
        elif method == "GET" and len(rest) == 1:
            if job := self.own_job(rest[0], auth):
                self.send_json(HTTPStatus.OK, job.to_json())
        elif method == "GET" and len(rest) == 2 and rest[1] == "musicxml":
            job = self.own_job(rest[0], auth)
            if job is None:
                return
            if job.status != "done":
                self.fail(HTTPStatus.CONFLICT, f"job is {job.status}", "not_ready")
                return
            index = int(query.get("movement", ["0"])[0] or 0)
            if not 0 <= index < len(job.movements):
                self.fail(HTTPStatus.NOT_FOUND, "no such movement", "not_found")
                return
            self.send_bytes(omr.extract_musicxml(job.movements[index]), "application/vnd.recordare.musicxml+xml")
        elif method == "DELETE" and len(rest) == 1:
            if self.own_job(rest[0], auth) is None:
                return
            with omr.jobs_lock:
                job = omr.jobs.pop(rest[0], None)
            # A running job finishes in the background; its files go when the worker is done with them.
            if job and job.status != "running":
                shutil.rmtree(job.dir, ignore_errors=True)
            self.send_json(HTTPStatus.NO_CONTENT, None)
        else:
            self.fail(HTTPStatus.NOT_FOUND, "not found", "not_found")

    def create_job(self, auth: Auth) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > omr.MAX_UPLOAD:
            self.fail(HTTPStatus.REQUEST_ENTITY_TOO_LARGE if length else HTTPStatus.BAD_REQUEST,
                      f"upload must be between 1 byte and {omr.MAX_UPLOAD // 1024 // 1024} MB", "body_size")
            return
        filename = omr.safe_filename(self.headers.get("X-Filename", "score.pdf"))
        if Path(filename).suffix not in omr.ALLOWED:
            self.fail(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, f"send one of {sorted(omr.ALLOWED)}", "file_type")
            return
        if omr.active_jobs(auth.user_id) >= omr.JOBS_PER_USER:
            self.fail(HTTPStatus.TOO_MANY_REQUESTS, f"You already have {omr.JOBS_PER_USER} scans waiting. Try again when one finishes.", "too_many_jobs")
            return
        job = omr.Job(uuid.uuid4().hex, filename, auth.user_id, self.device() or auth.device_id)
        job.dir.mkdir(parents=True, exist_ok=True)
        with open(job.dir / filename, "wb") as f:
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(remaining, 1 << 16))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        pages = omr.count_pages(job.dir / filename)
        if pages > omr.MAX_PAGES:
            shutil.rmtree(job.dir, ignore_errors=True)
            self.fail(HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                      f"That PDF has {pages} pages; the limit is {omr.MAX_PAGES}. Split it, or send just the pieces you need.", "too_many_pages")
            return
        omr.log_job(job, create=True)
        with omr.jobs_lock:
            omr.jobs[job.id] = job
        omr.work.put(job)
        self.send_json(HTTPStatus.ACCEPTED, job.to_json())
