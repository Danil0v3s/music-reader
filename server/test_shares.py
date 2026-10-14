"""Sharing scores and collections by code: read-only for others, importable as their own editable copy.

    cd server && python3 -m unittest
"""

import json
import re
import secrets
import unittest

from testsupport import apple, call, call_json, guest  # first: it sets up the environment

A = "AAAAAAAA-1111-4000-8000-000000000001"
B = "AAAAAAAA-1111-4000-8000-000000000002"


def score(title: str, sid: str) -> bytes:
    return json.dumps({"id": sid, "title": title, "composer": "Suzuki", "parts": [{"name": "Cello"}],
                       "created": "2026-10-01T10:00:00.000Z", "modified": "2026-10-01T10:00:00.000Z"}).encode()


def owner_with_scores() -> str:
    t = guest()["accessToken"]
    for sid, title in ((A, "Twinkle · Theme"), (B, "Twinkle · Variation A")):
        call("PUT", f"/library/scores/{sid}", score(title, sid), {"X-Modified": "1000"}, token=t)
    call("PUT", f"/library/scores/{A}/original", b"%PDF-1.4 the scan", token=t)
    doc = {"collections": [{"id": "C0000000-0000-4000-8000-000000000001", "name": "Suzuki Book 1", "scoreIds": [A, B],
                            "created": "2026-10-01T10:00:00.000Z"}], "modified": "2026-10-01T10:00:00.000Z"}
    call("PUT", "/library/collections", json.dumps(doc).encode(), {"X-Modified": "1000"}, token=t)
    return t


def share(token: str, kind: str, target: str) -> dict:
    status, body = call_json("POST", "/shares", {"kind": kind, "id": target}, token=token)
    assert status == 200, body
    return body


def open_code(code: str, token: str):
    return call_json("GET", f"/s/{code}", headers={"Accept": "application/json"}, token=token)


class ShareTests(unittest.TestCase):
    def test_share_a_score_view_it_and_import_a_copy(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        s = share(owner, "score", A)
        self.assertRegex(s["code"], r"^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$")
        self.assertEqual(share(owner, "score", A)["code"], s["code"], "sharing again gives the same code")

        status, shared = open_code(s["code"].lower().replace("-", ""), friend)   # any case, dash optional
        self.assertEqual(status, 200, shared)
        self.assertEqual((shared["kind"], shared["score"]["title"]), ("score", "Twinkle · Theme"))
        self.assertNotIn("original", json.dumps(shared), "the scan is never shared")

        status, imported = call_json("POST", f"/s/{s['code']}/import", {}, token=friend)
        self.assertEqual(status, 200, imported)
        new_id = imported["scores"][0]
        self.assertNotEqual(new_id, A)
        listing = call_json("GET", "/library", token=friend)[1]
        entry = next(x for x in listing["scores"] if x["id"] == new_id)
        self.assertEqual((entry["title"], entry["original"]), ("Twinkle · Theme", None))
        copy = call_json("GET", f"/library/scores/{new_id}", token=friend)[1]
        self.assertEqual(copy["id"], new_id)
        self.assertEqual(copy["importedFrom"]["code"], s["code"])
        # The copy's own date matches the server's record (so sync doesn't download it again and again).
        self.assertEqual(copy["modified"][:19], copy["created"][:19])

        # The copy is the friend's to edit; the owner's score doesn't change.
        call("PUT", f"/library/scores/{new_id}", score("My version", new_id), {"X-Modified": "9999"}, token=friend)
        self.assertEqual(json.loads(call("GET", f"/library/scores/{A}", token=owner)[1])["title"], "Twinkle · Theme")
        self.assertEqual(call_json("GET", "/shares", token=owner)[1]["shares"][0]["imports"], 1)

    def test_a_share_shows_the_owners_corrections(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        code = share(owner, "score", A)["code"]
        call("PUT", f"/library/scores/{A}", score("Twinkle · Theme (fixed bar 3)", A), {"X-Modified": "2000"}, token=owner)
        self.assertEqual(open_code(code, friend)[1]["score"]["title"], "Twinkle · Theme (fixed bar 3)")

    def test_stopping_a_share(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        code = share(owner, "score", A)["code"]
        self.assertEqual(call("DELETE", f"/shares/{code}", token=friend)[0], 404, "only the owner can stop it")
        self.assertEqual(call("DELETE", f"/shares/{code}", token=owner)[0], 204)
        status, body = open_code(code, friend)
        self.assertEqual((status, body["code"]), (404, "share_not_found"))
        self.assertEqual(call("POST", f"/s/{code}/import", {}, token=friend)[0], 404)
        self.assertEqual(call_json("GET", "/shares", token=owner)[1]["shares"], [])

    def test_deleting_the_score_stops_its_share(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        code = share(owner, "score", B)["code"]
        call("DELETE", f"/library/scores/{B}", headers={"X-Modified": "3000"}, token=owner)
        self.assertEqual(open_code(code, friend)[0], 404)

    def test_share_a_collection(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        code = share(owner, "collection", "C0000000-0000-4000-8000-000000000001")["code"]
        status, shared = open_code(code, friend)
        self.assertEqual((status, shared["collection"]["name"], len(shared["collection"]["scores"])), (200, "Suzuki Book 1", 2))
        _, imported = call_json("POST", f"/s/{code}/import", {}, token=friend)
        doc = json.loads(call("GET", "/library/collections", token=friend)[1])
        mine = next(c for c in doc["collections"] if c["id"] == imported["collection"])
        self.assertEqual((mine["name"], mine["scoreIds"]), ("Suzuki Book 1", imported["scores"]))
        self.assertEqual(len({s["id"] for s in call_json("GET", "/library", token=friend)[1]["scores"]}), 2)
        # Removing the collection from the owner's library stops the share.
        call("PUT", "/library/collections", json.dumps({"collections": []}).encode(), {"X-Modified": "5000"}, token=owner)
        self.assertEqual(open_code(code, friend)[0], 404)

    def test_only_your_own_music_can_be_shared(self):
        owner, friend = owner_with_scores(), guest()["accessToken"]
        status, body = call_json("POST", "/shares", {"kind": "score", "id": A}, token=friend)
        self.assertEqual((status, body["code"]), (404, "not_found"))
        self.assertEqual(call("POST", "/shares", {"kind": "score", "id": A})[0], 401)
        self.assertEqual(call("GET", "/s/ABCD2345", headers={"Accept": "application/json"})[0], 401, "the music needs a session")

    def test_link_in_a_browser(self):
        owner = owner_with_scores()
        code = share(owner, "score", A)["code"]
        status, page = call("GET", f"/s/{code.replace('-', '')}")
        self.assertEqual(status, 200)
        self.assertIn(b"musicreader://share/", page)
        self.assertIn(b"Twinkle", page)
        self.assertNotIn(b"Suzuki\"", page, "the page doesn't carry the notation")
        self.assertEqual(call("GET", "/s/NOPE2345")[0], 404)
        status, aasa = call_json("GET", "/.well-known/apple-app-site-association")
        self.assertEqual(aasa["applinks"]["details"][0]["components"], [{"/": "/s/*"}])

    def test_a_guests_shares_follow_it_into_its_account(self):
        g = guest()
        t = g["accessToken"]
        call("PUT", f"/library/scores/{A}", score("Shared by a guest", A), {"X-Modified": "1000"}, token=t)
        code = share(t, "score", A)["code"]
        sub = secrets.token_hex(6)
        call_json("POST", "/auth/apple", {"identityToken": apple.token(sub)})            # an existing account
        _, s = call_json("POST", "/auth/apple", {"identityToken": apple.token(sub)}, token=t)  # the guest signs in to it
        self.assertEqual(open_code(code, guest()["accessToken"])[0], 200)
        self.assertEqual([x["code"] for x in call_json("GET", "/shares", token=s["accessToken"])[1]["shares"]], [code])


if __name__ == "__main__":
    unittest.main()
