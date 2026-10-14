"""Users, ways to sign in, sessions and devices.

Sign-in methods
    apple    Sign in with Apple: the app's identity token, verified against Apple's keys (idtokens.py)
    google   Google Sign-In: the ID token, verified against Google's keys
    email    an address and a password (scrypt), with a verification email and password reset by email
    guest    no sign-in at all: an anonymous account tied to the device, upgraded later by attaching one of
             the above. Nothing is lost on upgrade, because it's the same account.

Signing in while a guest: if the method is new, it's attached to the guest account (the guest becomes a
full user); if it already belongs to another account, the guest's library moves into that account and the
guest account is deleted.

Sessions: an access token (1 hour) and a refresh token (90 days), both random and stored only as SHA-256
hashes. Refreshing rotates both. Signing out deletes the session; resetting a password or deleting the
account deletes all of them.

Devices: the app sends a random install id it keeps in its Keychain (X-Device). The server stores its hash
and which accounts used it. Free scans will be limited per device with this (paid scans).
"""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
import time
import uuid
from dataclasses import dataclass

import mailer
from db import Database
from idtokens import Claims
from library_store import LibraryStore

ACCESS_TTL = 3600
REFRESH_TTL = 90 * 86400
EMAIL_TOKEN_TTL = 2 * 86400
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
SCRYPT = {"n": 2 ** 14, "r": 8, "p": 1}


class AccountError(Exception):
    """A request the user can fix; `status` is the HTTP status to answer with."""

    def __init__(self, message: str, status: int = 400, code: str = "invalid"):
        super().__init__(message)
        self.status = status
        self.code = code


@dataclass
class Auth:
    user_id: str
    session_id: str
    device_id: str | None
    is_guest: bool


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    key = hashlib.scrypt(password.encode(), salt=salt, dklen=32, **SCRYPT)
    return f"scrypt${SCRYPT['n']}${SCRYPT['r']}${SCRYPT['p']}${salt.hex()}${key.hex()}"


def check_password(password: str, stored: str | None) -> bool:
    if not stored:
        return False
    try:
        _, n, r, p, salt, key = stored.split("$")
        got = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), dklen=32, n=int(n), r=int(r), p=int(p))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(got.hex(), key)


def normalise_email(email: str) -> str:
    email = (email or "").strip().lower()
    if not EMAIL_RE.match(email) or len(email) > 254:
        raise AccountError("Enter a valid email address.", code="email_invalid")
    return email


def check_new_password(password: str) -> None:
    if len(password or "") < 8:
        raise AccountError("Use at least 8 characters for the password.", code="password_short")
    if len(password) > 200:
        raise AccountError("That password is too long.", code="password_long")


class Accounts:
    def __init__(self, db: Database, library: LibraryStore, public_url: str = "http://localhost:8765", apple=None):
        self.db = db
        self.library = library
        self.public_url = public_url.rstrip("/")
        # apple_tokens.AppleClient: exchanges Sign in with Apple codes and revokes the tokens on deletion.
        self.apple = apple

    # Devices

    def register_device(self, install_id: str | None, platform: str = "", app_version: str = "") -> str | None:
        """Records an app install (by the hash of its Keychain id) and returns the device id."""
        if not install_id or len(install_id) > 200:
            return None
        device = sha("device:" + install_id)
        now = time.time()
        with self.db.tx() as c:
            c.execute("""INSERT INTO devices (id, first_seen, last_seen, platform, app_version) VALUES (?, ?, ?, ?, ?)
                         ON CONFLICT (id) DO UPDATE SET last_seen = excluded.last_seen,
                             platform = COALESCE(NULLIF(excluded.platform, ''), devices.platform),
                             app_version = COALESCE(NULLIF(excluded.app_version, ''), devices.app_version)""",
                      (device, now, now, platform[:40], app_version[:40]))
        return device

    def _touch_user_device(self, c, user: str, device: str | None, now: float) -> None:
        if device:
            c.execute("""INSERT INTO user_devices (user_id, device_id, first_seen, last_seen) VALUES (?, ?, ?, ?)
                         ON CONFLICT (user_id, device_id) DO UPDATE SET last_seen = excluded.last_seen""",
                      (user, device, now, now))

    # Sessions

    def _new_session(self, c, user: str, device: str | None) -> dict:
        now = time.time()
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        c.execute("""INSERT INTO sessions (id, user_id, device_id, access_hash, access_expires, refresh_hash, refresh_expires, created, last_used)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                  (uuid.uuid4().hex, user, device, sha(access), now + ACCESS_TTL, sha(refresh), now + REFRESH_TTL, now, now))
        c.execute("UPDATE users SET last_seen = ? WHERE id = ?", (now, user))
        self._touch_user_device(c, user, device, now)
        return {"accessToken": access, "refreshToken": refresh, "expiresIn": ACCESS_TTL}

    def authenticate(self, access_token: str | None, device: str | None = None) -> Auth | None:
        if not access_token:
            return None
        row = self.db.one("""SELECT s.id, s.user_id, s.device_id, s.access_expires, s.last_used, u.is_guest
                             FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.access_hash = ?""", (sha(access_token),))
        now = time.time()
        if row is None or row["access_expires"] < now:
            return None
        if now - row["last_used"] > 300:
            with self.db.tx() as c:
                c.execute("UPDATE sessions SET last_used = ? WHERE id = ?", (now, row["id"]))
                c.execute("UPDATE users SET last_seen = ? WHERE id = ?", (now, row["user_id"]))
                self._touch_user_device(c, row["user_id"], device or row["device_id"], now)
        return Auth(row["user_id"], row["id"], device or row["device_id"], bool(row["is_guest"]))

    def refresh(self, refresh_token: str, device: str | None = None) -> dict:
        now = time.time()
        with self.db.tx() as c:
            row = c.execute("SELECT * FROM sessions WHERE refresh_hash = ?", (sha(refresh_token or ""),)).fetchone()
            if row is None or row["refresh_expires"] < now:
                raise AccountError("Your session has ended. Sign in again.", 401, "session_expired")
            c.execute("DELETE FROM sessions WHERE id = ?", (row["id"],))
            return self._new_session(c, row["user_id"], device or row["device_id"])

    def sign_out(self, auth: Auth, everywhere: bool = False) -> None:
        with self.db.tx() as c:
            if everywhere:
                c.execute("DELETE FROM sessions WHERE user_id = ?", (auth.user_id,))
            else:
                c.execute("DELETE FROM sessions WHERE id = ?", (auth.session_id,))

    # Users

    def user_json(self, user: str) -> dict:
        u = self.db.one("SELECT * FROM users WHERE id = ?", (user,))
        if u is None:
            raise AccountError("No such account.", 404, "not_found")
        providers = [r["provider"] for r in self.db.query("SELECT provider FROM identities WHERE user_id = ? ORDER BY created", (user,))]
        return {"id": u["id"], "displayName": u["display_name"], "email": u["email"], "emailVerified": bool(u["email_verified"]),
                "isGuest": bool(u["is_guest"]), "providers": providers, "created": u["created"]}

    def _create_user(self, c, *, guest: bool, email: str | None = None, verified: bool = False, name: str = "") -> str:
        user, now = str(uuid.uuid4()), time.time()
        c.execute("""INSERT INTO users (id, created, last_seen, display_name, email, email_verified, is_guest)
                     VALUES (?, ?, ?, ?, ?, ?, ?)""", (user, now, now, name[:100], email, int(verified), int(guest)))
        return user

    def create_guest(self, device: str | None) -> dict:
        with self.db.tx() as c:
            user = self._create_user(c, guest=True)
            tokens = self._new_session(c, user, device)
        return {**tokens, "user": self.user_json(user)}

    def _finish_sign_in(self, user: str, device: str | None, current: Auth | None) -> dict:
        """Moves a guest's library into the account it signed in to, and opens a session."""
        merged = 0
        if current and current.is_guest and current.user_id != user:
            merged = self.library.move_all(current.user_id, user, time.time())
            with self.db.tx() as c:
                c.execute("DELETE FROM users WHERE id = ?", (current.user_id,))
        elif current and current.user_id == user:
            with self.db.tx() as c:
                c.execute("DELETE FROM sessions WHERE id = ?", (current.session_id,))
        with self.db.tx() as c:
            tokens = self._new_session(c, user, device)
        return {**tokens, "user": self.user_json(user), "mergedScores": merged}

    def sign_in_with_provider(self, provider: str, claims: Claims, device: str | None, current: Auth | None,
                              name: str = "", authorization_code: str = "") -> dict:
        """Apple or Google: finds the account for this identity, or creates one (or upgrades the current
        guest to it). For Apple, the authorization code is exchanged for a refresh token, kept so it can be
        revoked when the account is deleted."""
        refresh = self.apple.exchange_code(authorization_code) if provider == "apple" and self.apple and authorization_code else None
        email = claims.email.lower() if claims.email else None
        display = (name or claims.name or "").strip()
        with self.db.tx() as c:
            ident = c.execute("SELECT user_id FROM identities WHERE provider = ? AND subject = ?",
                              (provider, claims.subject)).fetchone()
            if ident:
                user = ident["user_id"]
                c.execute("""UPDATE users SET email = COALESCE(email, ?), email_verified = MAX(email_verified, ?),
                                 display_name = CASE WHEN display_name = '' THEN ? ELSE display_name END WHERE id = ?""",
                          (email, int(claims.email_verified and email is not None), display[:100], user))
            else:
                if current and current.is_guest:
                    user = current.user_id
                    c.execute("""UPDATE users SET is_guest = 0, email = COALESCE(email, ?), email_verified = ?,
                                     display_name = CASE WHEN display_name = '' THEN ? ELSE display_name END WHERE id = ?""",
                              (email, int(claims.email_verified and email is not None), display[:100], user))
                else:
                    user = self._create_user(c, guest=False, email=email, verified=claims.email_verified, name=display)
                c.execute("INSERT INTO identities (provider, subject, user_id, email, created) VALUES (?, ?, ?, ?, ?)",
                          (provider, claims.subject, user, email, time.time()))
            if refresh:
                c.execute("UPDATE identities SET provider_refresh_token = ? WHERE provider = ? AND subject = ?",
                          (refresh, provider, claims.subject))
        return self._finish_sign_in(user, device, current)

    def link_provider(self, auth: Auth, provider: str, claims: Claims) -> dict:
        """Adds a sign-in method to the signed-in account."""
        with self.db.tx() as c:
            ident = c.execute("SELECT user_id FROM identities WHERE provider = ? AND subject = ?",
                              (provider, claims.subject)).fetchone()
            if ident and ident["user_id"] != auth.user_id:
                raise AccountError("That account is already used to sign in to another Music Reader account.", 409, "identity_taken")
            if not ident:
                c.execute("INSERT INTO identities (provider, subject, user_id, email, created) VALUES (?, ?, ?, ?, ?)",
                          (provider, claims.subject, auth.user_id, claims.email, time.time()))
                c.execute("UPDATE users SET is_guest = 0 WHERE id = ?", (auth.user_id,))
        return self.user_json(auth.user_id)

    # Email and password

    def email_sign_up(self, email: str, password: str, name: str, device: str | None, current: Auth | None) -> dict:
        email = normalise_email(email)
        check_new_password(password)
        with self.db.tx() as c:
            if c.execute("SELECT 1 FROM identities WHERE provider = 'email' AND subject = ?", (email,)).fetchone():
                raise AccountError("There's already an account with this email. Sign in instead.", 409, "email_taken")
            if current and current.is_guest:
                user = current.user_id
                c.execute("UPDATE users SET is_guest = 0, email = ?, email_verified = 0, display_name = ? WHERE id = ?",
                          (email, (name or "").strip()[:100], user))
            elif current:
                raise AccountError("You're already signed in.", 409, "signed_in")
            else:
                user = self._create_user(c, guest=False, email=email, name=(name or "").strip())
            c.execute("INSERT INTO identities (provider, subject, user_id, email, password_hash, created) VALUES ('email', ?, ?, ?, ?, ?)",
                      (email, user, email, hash_password(password), time.time()))
        self._send_email_link(user, email, "verify")
        return self._finish_sign_in(user, device, current)

    def email_sign_in(self, email: str, password: str, device: str | None, current: Auth | None) -> dict:
        email = (email or "").strip().lower()
        row = self.db.one("SELECT user_id, password_hash FROM identities WHERE provider = 'email' AND subject = ?", (email,))
        if not check_password(password or "", row["password_hash"] if row else None):
            raise AccountError("Wrong email or password.", 401, "bad_credentials")
        return self._finish_sign_in(row["user_id"], device, current)

    def _send_email_link(self, user: str, email: str, purpose: str) -> None:
        token = secrets.token_urlsafe(32)
        with self.db.tx() as c:
            c.execute("INSERT INTO email_tokens (token_hash, user_id, purpose, email, expires) VALUES (?, ?, ?, ?, ?)",
                      (sha(token), user, purpose, email, time.time() + EMAIL_TOKEN_TTL))
        if purpose == "verify":
            mailer.send(email, "Confirm your email for Music Reader",
                        f"Open this link to confirm your email address:\n\n{self.public_url}/auth/email/verify?token={token}\n\n"
                        "If you didn't create a Music Reader account, ignore this email.")
        else:
            mailer.send(email, "Reset your Music Reader password",
                        f"Open this link to choose a new password:\n\n{self.public_url}/auth/email/reset?token={token}\n\n"
                        "The link works for two days. If you didn't ask for this, ignore this email; your password hasn't changed.")

    def _use_email_token(self, token: str, purpose: str) -> tuple[str, str]:
        with self.db.tx() as c:
            row = c.execute("SELECT * FROM email_tokens WHERE token_hash = ? AND purpose = ?", (sha(token or ""), purpose)).fetchone()
            if row is None or row["used"] or row["expires"] < time.time():
                raise AccountError("This link has expired or was already used.", 400, "link_expired")
            c.execute("UPDATE email_tokens SET used = 1 WHERE token_hash = ?", (row["token_hash"],))
            return row["user_id"], row["email"]

    def verify_email(self, token: str) -> None:
        user, email = self._use_email_token(token, "verify")
        with self.db.tx() as c:
            c.execute("UPDATE users SET email_verified = 1 WHERE id = ? AND email = ?", (user, email))

    def request_password_reset(self, email: str) -> None:
        """Always succeeds from the caller's point of view, so it can't be used to find out who has an account."""
        email = (email or "").strip().lower()
        row = self.db.one("SELECT user_id FROM identities WHERE provider = 'email' AND subject = ?", (email,))
        if row:
            self._send_email_link(row["user_id"], email, "reset")

    def reset_password(self, token: str, password: str) -> None:
        check_new_password(password)
        user, email = self._use_email_token(token, "reset")
        with self.db.tx() as c:
            c.execute("UPDATE identities SET password_hash = ? WHERE provider = 'email' AND subject = ? AND user_id = ?",
                      (hash_password(password), email, user))
            # The link proves the address, and every existing session ends.
            c.execute("UPDATE users SET email_verified = 1 WHERE id = ? AND email = ?", (user, email))
            c.execute("DELETE FROM sessions WHERE user_id = ?", (user,))

    # Deletion

    def delete_user(self, user: str) -> None:
        """Deletes the account and everything in it, and revokes its Sign in with Apple token. The scan log
        keeps its rows without the user: the device still used those scans."""
        if self.apple:
            for r in self.db.query("SELECT provider_refresh_token FROM identities WHERE user_id = ? AND provider = 'apple' "
                                   "AND provider_refresh_token IS NOT NULL", (user,)):
                self.apple.revoke(r["provider_refresh_token"])
        self.library.delete_user(user)
        with self.db.tx() as c:
            c.execute("DELETE FROM users WHERE id = ?", (user,))

    def delete_stale_guests(self, idle_days: int = 365) -> int:
        cutoff = time.time() - idle_days * 86400
        stale = [r["id"] for r in self.db.query("SELECT id FROM users WHERE is_guest = 1 AND last_seen < ?", (cutoff,))]
        for user in stale:
            self.delete_user(user)
        return len(stale)
