"""The server's database: SQLite in the data volume (Python's own sqlite3, so the image needs nothing more).

One connection, shared by the request threads behind a lock: requests are short, SQLite serialises writes
anyway, and a lock makes every `tx()` block a real transaction (a scan credit must never be spent twice).
The schema only grows through MIGRATIONS, applied in order at startup and recorded in `schema_version`.

Ownership: every score, original and collection belongs to one user. Score ids come from the app and are
only unique per user (the bundled étude has the same id on every install), so scores are keyed by
(user, id).

Some tables are kept for later work, so the data exists when it's needed:
    devices / user_devices   which app installs exist and which accounts each has used (free scans are
                             limited per device, not per account)
    scan_jobs                every recognition: who, from which device, what kind, how many pages, outcome
    scan_credits             the scan credit ledger (paid scans); nothing writes to it yet
"""

from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

MIGRATIONS: list[str] = [
    # 1: accounts, the library per user, devices and the scan log.
    """
    CREATE TABLE users (
        id              TEXT PRIMARY KEY,           -- UUID
        created         REAL NOT NULL,
        last_seen       REAL NOT NULL,
        display_name    TEXT NOT NULL DEFAULT '',
        email           TEXT,                       -- contact email (verified or not); may be absent (Apple private relay hidden, guests)
        email_verified  INTEGER NOT NULL DEFAULT 0,
        is_guest        INTEGER NOT NULL DEFAULT 0,
        unlimited_scans INTEGER NOT NULL DEFAULT 0  -- paid scans: the one-off "unlimited" purchase
    );
    -- Ways to sign in to a user: ('apple', sub), ('google', sub), ('email', lowercased address).
    CREATE TABLE identities (
        provider        TEXT NOT NULL,
        subject         TEXT NOT NULL,
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        email           TEXT,
        password_hash   TEXT,                       -- email identities only
        created         REAL NOT NULL,
        PRIMARY KEY (provider, subject)
    );
    CREATE INDEX identities_user ON identities(user_id);
    -- Tokens are stored as SHA-256 hashes; the client holds the only copy of the token itself.
    CREATE TABLE sessions (
        id              TEXT PRIMARY KEY,
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        device_id       TEXT REFERENCES devices(id),
        access_hash     TEXT NOT NULL UNIQUE,
        access_expires  REAL NOT NULL,
        refresh_hash    TEXT NOT NULL UNIQUE,
        refresh_expires REAL NOT NULL,
        created         REAL NOT NULL,
        last_used       REAL NOT NULL
    );
    CREATE INDEX sessions_user ON sessions(user_id);
    -- One-off links sent by email: verify an address, reset a password.
    CREATE TABLE email_tokens (
        token_hash      TEXT PRIMARY KEY,
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        purpose         TEXT NOT NULL,              -- 'verify' | 'reset'
        email           TEXT NOT NULL,
        expires         REAL NOT NULL,
        used            INTEGER NOT NULL DEFAULT 0
    );
    -- An app install, identified by a random id the app keeps in its Keychain (stored hashed). Survives
    -- reinstalls; DeviceCheck/App Attest data joins it with the paid scans work.
    CREATE TABLE devices (
        id              TEXT PRIMARY KEY,           -- SHA-256 of the install id
        first_seen      REAL NOT NULL,
        last_seen       REAL NOT NULL,
        platform        TEXT NOT NULL DEFAULT '',
        app_version     TEXT NOT NULL DEFAULT '',
        free_scans_used INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE user_devices (
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        device_id       TEXT NOT NULL REFERENCES devices(id),
        first_seen      REAL NOT NULL,
        last_seen       REAL NOT NULL,
        PRIMARY KEY (user_id, device_id)
    );
    CREATE INDEX user_devices_device ON user_devices(device_id);
    CREATE TABLE scores (
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        id              TEXT NOT NULL,              -- the app's UUID
        modified        REAL NOT NULL,              -- the client's modification time (unix seconds, ms precision)
        deleted         INTEGER NOT NULL DEFAULT 0, -- tombstone
        title           TEXT NOT NULL DEFAULT '',
        composer        TEXT NOT NULL DEFAULT '',
        body            BLOB,                       -- the app's score JSON; NULL once deleted
        has_original    INTEGER NOT NULL DEFAULT 0, -- the PDF lives on disk (see library_store)
        imported_from   TEXT,                       -- JSON: where a score imported from a share came from
        PRIMARY KEY (user_id, id)
    );
    CREATE TABLE collections (
        user_id         TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        modified        REAL NOT NULL,
        body            BLOB NOT NULL
    );
    -- Every recognition. Kept when an account is deleted (user_id cleared): the device still used its scans.
    CREATE TABLE scan_jobs (
        id              TEXT PRIMARY KEY,
        user_id         TEXT REFERENCES users(id) ON DELETE SET NULL,
        device_id       TEXT REFERENCES devices(id),
        filename        TEXT NOT NULL,
        kind            TEXT NOT NULL,              -- 'pdf' | 'image'
        bytes           INTEGER NOT NULL,
        pages           INTEGER NOT NULL,
        status          TEXT NOT NULL,              -- queued | running | done | failed
        error           TEXT,
        movements       INTEGER NOT NULL DEFAULT 0,
        created         REAL NOT NULL,
        started         REAL,
        finished        REAL
    );
    CREATE INDEX scan_jobs_user ON scan_jobs(user_id);
    CREATE INDEX scan_jobs_device ON scan_jobs(device_id);
    -- Paid scans: an append-only ledger (+3 free, +10 pack, -1 per scan, +1 refund); the balance is the sum.
    CREATE TABLE scan_credits (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        delta           INTEGER NOT NULL,
        reason          TEXT NOT NULL,
        reference       TEXT,
        created         REAL NOT NULL,
        UNIQUE (reason, reference)
    );
    CREATE INDEX scan_credits_user ON scan_credits(user_id);
    """,
]


class Database:
    def __init__(self, path: Path | str):
        if isinstance(path, Path):
            path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.execute("PRAGMA journal_mode = WAL")
        self.conn.execute("PRAGMA busy_timeout = 5000")
        self.migrate()

    def migrate(self) -> None:
        with self.lock:
            self.conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
            row = self.conn.execute("SELECT version FROM schema_version").fetchone()
            current = row["version"] if row else 0
            for version, script in enumerate(MIGRATIONS[current:], start=current + 1):
                # The schema change and its version number commit together.
                self.conn.executescript(f"BEGIN; {script}; DELETE FROM schema_version; "
                                        f"INSERT INTO schema_version (version) VALUES ({version}); COMMIT;")

    @property
    def version(self) -> int:
        return self.conn.execute("SELECT version FROM schema_version").fetchone()["version"]

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        """A write transaction: BEGIN IMMEDIATE takes SQLite's write lock up front, so read-then-write
        sequences (spend a credit, rotate a token) can't interleave."""
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                yield self.conn
            except BaseException:
                self.conn.execute("ROLLBACK")
                raise
            else:
                self.conn.execute("COMMIT")

    def query(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def one(self, sql: str, args: tuple = ()) -> sqlite3.Row | None:
        with self.lock:
            return self.conn.execute(sql, args).fetchone()
