"""Accounts, sessions, sign-in methods, guests and each user's private library.

    cd server && python3 -m unittest
"""

import json
import re
import secrets
import time
import unittest

from testsupport import TMP, apple, call, call_json, google, guest, omr_server  # first: it sets up the environment

import api  # noqa: E402
import mailer  # noqa: E402

ETUDE = "E7D0E7D0-0000-4000-8000-000000000001"   # the bundled score: the same id in every library


def score_json(title: str, score_id: str = ETUDE) -> bytes:
    return json.dumps({"id": score_id, "title": title, "composer": "Trad.", "parts": []}).encode()


def put_score(token: str, score_id: str, title: str, modified: float = 1000.0) -> int:
    return call("PUT", f"/library/scores/{score_id}", score_json(title, score_id), {"X-Modified": str(modified)}, token=token)[0]


def listing(token: str) -> dict:
    status, body = call_json("GET", "/library", token=token)
    assert status == 200, body
    return body


def last_link(path: str) -> str:
    text = mailer.outbox[-1].get_content()
    return re.search(rf"https://music\.test{re.escape(path)}\?token=(\S+)", text).group(1)


def new_email() -> str:
    return f"cellist-{secrets.token_hex(4)}@example.com"


class SessionTests(unittest.TestCase):
    def test_guest_account(self):
        g = guest()
        status, me = call_json("GET", "/me", token=g["accessToken"])
        self.assertEqual(status, 200)
        self.assertTrue(me["isGuest"])
        self.assertEqual(me["providers"], [])

    def test_everything_but_health_and_sign_in_needs_a_session(self):
        for method, path in [("GET", "/library"), ("GET", "/me"), ("POST", "/jobs"), ("GET", "/library/collections")]:
            self.assertEqual(call(method, path)[0], 401, path)
        self.assertEqual(call("GET", "/library", token="made-up")[0], 401)

    def test_refresh_rotates_both_tokens(self):
        g = guest()
        status, fresh = call_json("POST", "/auth/refresh", {"refreshToken": g["refreshToken"]})
        self.assertEqual(status, 200)
        self.assertEqual(call("GET", "/me", token=fresh["accessToken"])[0], 200)
        self.assertEqual(call("GET", "/me", token=g["accessToken"])[0], 401, "the old access token stops working")
        self.assertEqual(call("POST", "/auth/refresh", {"refreshToken": g["refreshToken"]})[0], 401, "a refresh token works once")

    def test_sign_out(self):
        g = guest()
        self.assertEqual(call("POST", "/auth/signout", {}, token=g["accessToken"])[0], 204)
        self.assertEqual(call("GET", "/me", token=g["accessToken"])[0], 401)

    def test_rate_limit(self):
        limiter = api.RateLimiter(2, 60)
        self.assertTrue(limiter.allow("ip") and limiter.allow("ip"))
        self.assertFalse(limiter.allow("ip"))
        self.assertTrue(limiter.allow("other ip"))


class EmailTests(unittest.TestCase):
    def test_sign_up_verify_sign_in(self):
        email = new_email()
        status, s = call_json("POST", "/auth/email/signup", {"email": email.upper(), "password": "pizzicato", "name": "Ana"})
        self.assertEqual(status, 200, s)
        self.assertEqual((s["user"]["email"], s["user"]["emailVerified"], s["user"]["providers"]), (email, False, ["email"]))
        token = last_link("/auth/email/verify")
        self.assertEqual(call("GET", f"/auth/email/verify?token={token}")[0], 200)
        self.assertEqual(call("GET", f"/auth/email/verify?token={token}")[0], 400, "a link works once")
        self.assertTrue(call_json("GET", "/me", token=s["accessToken"])[1]["emailVerified"])

        self.assertEqual(call("POST", "/auth/email/signin", {"email": email, "password": "wrong-one"})[0], 401)
        status, again = call_json("POST", "/auth/email/signin", {"email": email, "password": "pizzicato"})
        self.assertEqual((status, again["user"]["id"]), (200, s["user"]["id"]))

    def test_sign_up_rules(self):
        self.assertEqual(call_json("POST", "/auth/email/signup", {"email": "not-an-email", "password": "pizzicato"})[1]["code"], "email_invalid")
        self.assertEqual(call_json("POST", "/auth/email/signup", {"email": new_email(), "password": "short"})[1]["code"], "password_short")
        email = new_email()
        call("POST", "/auth/email/signup", {"email": email, "password": "pizzicato"})
        status, body = call_json("POST", "/auth/email/signup", {"email": email, "password": "different1"})
        self.assertEqual((status, body["code"]), (409, "email_taken"))

    def test_password_reset_ends_every_session(self):
        email = new_email()
        _, s = call_json("POST", "/auth/email/signup", {"email": email, "password": "pizzicato"})
        self.assertEqual(call("POST", "/auth/email/reset-request", {"email": email})[0], 204)
        token = last_link("/auth/email/reset")
        self.assertIn(b"<form", call("GET", f"/auth/email/reset?token={token}")[1])
        self.assertEqual(call("POST", "/auth/email/reset", {"token": token, "password": "arco-arco"})[0], 204)
        self.assertEqual(call("GET", "/me", token=s["accessToken"])[0], 401)
        self.assertEqual(call("POST", "/auth/email/signin", {"email": email, "password": "arco-arco"})[0], 200)
        # Unknown addresses look the same from outside.
        self.assertEqual(call("POST", "/auth/email/reset-request", {"email": "nobody@example.com"})[0], 204)

    def test_reset_from_the_web_form(self):
        email = new_email()
        call("POST", "/auth/email/signup", {"email": email, "password": "pizzicato"})
        call("POST", "/auth/email/reset-request", {"email": email})
        token = last_link("/auth/email/reset")
        status, page = call("POST", "/auth/email/reset", f"token={token}&password=spiccato1".encode(),
                            {"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 200)
        self.assertIn(b"Password changed", page)


class ProviderTests(unittest.TestCase):
    def test_apple_sign_in(self):
        sub = secrets.token_hex(6)
        status, s = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub, nonce="n0nce", email="a@privaterelay.appleid.com"),
                                                      "nonce": "n0nce", "name": "Bea"})
        self.assertEqual(status, 200, s)
        self.assertEqual((s["user"]["providers"], s["user"]["displayName"]), (["apple"], "Bea"))
        # Signing in again finds the same account.
        _, again = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub)})
        self.assertEqual(again["user"]["id"], s["user"]["id"])

    def test_apple_tokens_are_checked(self):
        sub = secrets.token_hex(6)
        cases = {
            "bad signature": apple.token(sub, tamper=True),
            "another app": apple.token(sub, aud="com.example.other"),
            "expired": apple.token(sub, exp=time.time() - 3600),
        }
        for why, token in cases.items():
            status, body = call_json("POST", "/auth/apple", {"identityToken": token})
            self.assertEqual((status, body["code"]), (401, "token_invalid"), why)
        status, _ = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub, nonce="right"), "nonce": "wrong"})
        self.assertEqual(status, 401, "nonce mismatch")
        status, _ = call_json("POST", "/auth/apple", {"identityToken": google.token(sub)})
        self.assertEqual(status, 401, "Google's token isn't Apple's")

    def test_google_sign_in(self):
        status, s = call_json("POST", "/auth/google", {"idToken": google.token(secrets.token_hex(6), email="c@gmail.com")})
        self.assertEqual(status, 200, s)
        self.assertEqual((s["user"]["providers"], s["user"]["email"], s["user"]["emailVerified"]), (["google"], "c@gmail.com", True))

    def test_link_a_second_method(self):
        _, s = call_json("POST", "/auth/email/signup", {"email": new_email(), "password": "pizzicato"})
        sub = secrets.token_hex(6)
        status, me = call_json("POST", "/me/link/apple", {"identityToken": apple.token(sub)}, token=s["accessToken"])
        self.assertEqual((status, me["providers"]), (200, ["email", "apple"]))
        _, other = call_json("POST", "/auth/email/signup", {"email": new_email(), "password": "pizzicato"})
        status, body = call_json("POST", "/me/link/apple", {"identityToken": apple.token(sub)}, token=other["accessToken"])
        self.assertEqual((status, body["code"]), (409, "identity_taken"))


class GuestUpgradeTests(unittest.TestCase):
    def test_signing_up_keeps_the_guest_library(self):
        g = guest()
        put_score(g["accessToken"], ETUDE, "Étude in D")
        status, s = call_json("POST", "/auth/email/signup", {"email": new_email(), "password": "pizzicato"}, token=g["accessToken"])
        self.assertEqual(status, 200, s)
        self.assertEqual(s["user"]["id"], g["user"]["id"], "same account, now with a sign-in method")
        self.assertFalse(s["user"]["isGuest"])
        self.assertEqual([x["title"] for x in listing(s["accessToken"])["scores"]], ["Étude in D"])
        self.assertEqual(call("GET", "/me", token=g["accessToken"])[0], 401, "the guest session is replaced")

    def test_guest_signing_in_to_an_existing_account_brings_its_scores(self):
        sub = secrets.token_hex(6)
        _, owner = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub)})
        mine = "11111111-0000-4000-8000-000000000001"
        put_score(owner["accessToken"], mine, "Already mine", 500)
        put_score(owner["accessToken"], ETUDE, "Étude (older)", 500)
        g = guest()
        put_score(g["accessToken"], ETUDE, "Étude (newer, from the guest)", 900)
        call("PUT", "/library/collections", json.dumps({"collections": [{"id": "C1", "name": "From guest", "scoreIds": [ETUDE]}]}).encode(),
             {"X-Modified": "900"}, token=g["accessToken"])

        status, s = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub)}, token=g["accessToken"])
        self.assertEqual((status, s["user"]["id"], s["mergedScores"]), (200, owner["user"]["id"], 1))
        titles = sorted(x["title"] for x in listing(s["accessToken"])["scores"])
        self.assertEqual(titles, ["Already mine", "Étude (newer, from the guest)"], "the newer copy wins")
        collections = json.loads(call("GET", "/library/collections", token=s["accessToken"])[1])
        self.assertEqual([c["name"] for c in collections["collections"]], ["From guest"])
        self.assertEqual(call("GET", "/me", token=g["accessToken"])[0], 401, "the guest account is gone")


class LibraryTests(unittest.TestCase):
    ID = "6F1C2A1E-0B6A-4C0E-9C7B-6A7A3E8D2F11"

    def setUp(self):
        self.token = guest()["accessToken"]

    def entry(self, score_id):
        return next((s for s in listing(self.token)["scores"] if s["id"] == score_id), None)

    def test_score_round_trip_and_tombstone(self):
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", score_json("Early one morning", self.ID), {"X-Modified": "1000.5"}, token=self.token)[0], 204)
        entry = self.entry(self.ID)
        self.assertEqual((entry["title"], entry["modified"], entry["deleted"]), ("Early one morning", 1000.5, False))
        status, body = call_json("GET", f"/library/scores/{self.ID}", token=self.token)
        self.assertEqual((status, body["composer"]), (200, "Trad."))

        self.assertEqual(call("PUT", f"/library/scores/{self.ID}/original", b"%PDF-1.4 x", token=self.token)[0], 204)
        self.assertEqual(self.entry(self.ID)["original"], "pdf")
        self.assertEqual(call("GET", f"/library/scores/{self.ID}/original", token=self.token)[1], b"%PDF-1.4 x")

        self.assertEqual(call("DELETE", f"/library/scores/{self.ID}", headers={"X-Modified": "2000"}, token=self.token)[0], 204)
        entry = self.entry(self.ID)
        self.assertEqual((entry["deleted"], entry["modified"]), (True, 2000))
        self.assertEqual(call("GET", f"/library/scores/{self.ID}", token=self.token)[0], 404)
        self.assertEqual(call("GET", f"/library/scores/{self.ID}/original", token=self.token)[0], 404)

    def test_collections_document(self):
        doc = json.dumps({"collections": [{"name": "Book 1"}]}).encode()
        self.assertEqual(call("PUT", "/library/collections", doc, {"X-Modified": "3000"}, token=self.token)[0], 204)
        self.assertEqual(listing(self.token)["collections"]["modified"], 3000)
        self.assertEqual(json.loads(call("GET", "/library/collections", token=self.token)[1])["collections"][0]["name"], "Book 1")

    def test_rejects_bad_input(self):
        t = self.token
        self.assertEqual(call("PUT", "/library/scores/not-a-uuid", b"{}", {"X-Modified": "1"}, token=t)[0], 400)
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", b"[1,2]", {"X-Modified": "1"}, token=t)[0], 400)
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", b"{}", token=t)[0], 400, "X-Modified is required")
        other = "11111111-2222-3333-4444-555555555555"
        self.assertEqual(call("PUT", f"/library/scores/{other}/original", b"%PDF", token=t)[0], 404, "score first")

    def test_libraries_are_private(self):
        a, b = guest()["accessToken"], guest()["accessToken"]
        put_score(a, ETUDE, "A's étude")
        put_score(b, ETUDE, "B's étude")
        put_score(a, self.ID, "Only A has this")
        call("PUT", f"/library/scores/{self.ID}/original", b"%PDF-1.4 secret", token=a)
        call("PUT", "/library/collections", b'{"collections": [{"name": "A only"}]}', {"X-Modified": "1"}, token=a)

        self.assertEqual(json.loads(call("GET", f"/library/scores/{ETUDE}", token=b)[1])["title"], "B's étude")
        self.assertEqual([s["title"] for s in listing(b)["scores"]], ["B's étude"])
        for path in (f"/library/scores/{self.ID}", f"/library/scores/{self.ID}/original"):
            self.assertEqual(call("GET", path, token=b)[0], 404, f"{path} is someone else's")
        self.assertEqual(call("GET", "/library/collections", token=b)[0], 404)
        # Deleting "the same" score in B's library doesn't touch A's.
        call("DELETE", f"/library/scores/{ETUDE}", headers={"X-Modified": "5000"}, token=b)
        self.assertEqual(json.loads(call("GET", f"/library/scores/{ETUDE}", token=a)[1])["title"], "A's étude")


class DeletionAndDevicesTests(unittest.TestCase):
    def test_deleting_the_account(self):
        device = secrets.token_hex(8)
        g = guest(device)
        t = g["accessToken"]
        put_score(t, ETUDE, "Étude")
        call("PUT", f"/library/scores/{ETUDE}/original", b"%PDF-1.4 x", token=t)
        status, body = call_json("POST", "/jobs", b"%PDF-1.4 fake", headers={"X-Filename": "page.pdf"}, token=t, device=device)
        self.assertEqual(status, 202, body)
        for _ in range(50):
            if call_json("GET", f"/jobs/{body['id']}", token=t)[1]["status"] in ("done", "failed"):
                break
            time.sleep(0.1)

        self.assertEqual(call("DELETE", "/me", token=t)[0], 204)
        self.assertEqual(call("GET", "/me", token=t)[0], 401)
        db = omr_server.database
        self.assertIsNone(db.one("SELECT 1 FROM users WHERE id = ?", (g["user"]["id"],)))
        self.assertIsNone(db.one("SELECT 1 FROM scores WHERE user_id = ?", (g["user"]["id"],)))
        self.assertFalse((TMP / "data" / "originals" / g["user"]["id"]).exists())
        # The scan stays on record against the device (free scans are per device), without the account.
        job = db.one("SELECT user_id, device_id, pages, status FROM scan_jobs WHERE id = ?", (body["id"],))
        self.assertIsNone(job["user_id"])
        self.assertIsNotNone(job["device_id"])

    def test_devices_and_their_accounts_are_recorded(self):
        device = secrets.token_hex(8)
        first, second = guest(device), guest(device)
        db = omr_server.database
        rows = db.query("""SELECT ud.user_id FROM user_devices ud JOIN devices d ON d.id = ud.device_id
                           WHERE d.id = (SELECT device_id FROM sessions WHERE user_id = ?)""", (first["user"]["id"],))
        self.assertEqual({r["user_id"] for r in rows}, {first["user"]["id"], second["user"]["id"]})
        self.assertIsNone(db.one("SELECT 1 FROM devices WHERE id = ?", (device,)), "only the hash of the install id is kept")

    def test_scans_record_pages(self):
        t = guest()["accessToken"]
        pdf = b"%PDF-1.4\n1 0 obj << /Type /Pages /Count 2 >>\n2 0 obj << /Type /Page >>\n3 0 obj << /Type/Page >>\n"
        _, body = call_json("POST", "/jobs", pdf, headers={"X-Filename": "two pages.pdf"}, token=t)
        row = omr_server.database.one("SELECT kind, pages FROM scan_jobs WHERE id = ?", (body["id"],))
        self.assertEqual((row["kind"], row["pages"]), ("pdf", 2))
        other = guest()["accessToken"]
        self.assertEqual(call("GET", f"/jobs/{body['id']}", token=other)[0], 404, "jobs are private too")


class LegacyImportTests(unittest.TestCase):
    def test_import_a_library_from_before_accounts(self):
        folder = TMP / "legacy"
        (folder / "scores").mkdir(parents=True)
        (folder / "originals").mkdir()
        sid, gone = "AAAAAAAA-0000-4000-8000-000000000001", "AAAAAAAA-0000-4000-8000-000000000002"
        (folder / "scores" / f"{sid}.json").write_bytes(score_json("Prelude", sid))
        (folder / "originals" / f"{sid}.pdf").write_bytes(b"%PDF-1.4 prelude")
        (folder / "collections.json").write_text('{"collections": [{"name": "Bach"}]}')
        (folder / "index.json").write_text(json.dumps({"scores": {
            sid: {"modified": 100, "deleted": False, "title": "Prelude", "composer": "", "original": "pdf"},
            gone: {"modified": 200, "deleted": True, "title": "", "composer": "", "original": None}},
            "collections": {"modified": 300}}))
        g = guest()
        library = omr_server.accounts_service.library
        self.assertEqual(library.import_legacy(folder, g["user"]["id"]), 1)
        entries = {s["id"]: s for s in listing(g["accessToken"])["scores"]}
        self.assertEqual((entries[sid]["title"], entries[sid]["original"], entries[gone]["deleted"]), ("Prelude", "pdf", True))
        self.assertEqual(call("GET", f"/library/scores/{sid}/original", token=g["accessToken"])[1], b"%PDF-1.4 prelude")


if __name__ == "__main__":
    unittest.main()
