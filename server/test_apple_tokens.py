"""Sign in with Apple's server side: the ES256 client secret (checked against OpenSSL) and revoking a deleted
account's Apple token.

    cd server && python3 -m unittest
"""

import base64
import json
import secrets
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from testsupport import apple, call_json, omr_server  # first: it sets up the environment

import apple_tokens  # noqa: E402
from apple_tokens import AppleClient, multiply, private_key_from_p8, sign_es256  # noqa: E402

OPENSSL = shutil.which("openssl")


def der_signature(raw: bytes) -> bytes:
    """JWS (r || s) to the DER form OpenSSL verifies."""
    def integer(b: bytes) -> bytes:
        b = b.lstrip(b"\x00")
        if not b or b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class EcdsaTests(unittest.TestCase):
    def test_public_key_arithmetic(self):
        # n·G is the point at infinity; 2·G computed twice ways agrees.
        self.assertIsNone(multiply(apple_tokens.N))
        self.assertEqual(multiply(2), apple_tokens._add(apple_tokens.G, apple_tokens.G))

    @unittest.skipIf(OPENSSL is None, "openssl not installed")
    def test_signature_verifies_with_openssl(self):
        folder = Path(tempfile.mkdtemp())
        key = folder / "AuthKey_TEST.p8"
        # The same form Apple hands out: an EC P-256 key in PKCS#8 PEM.
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                       check=True, capture_output=True)
        subprocess.run([OPENSSL, "pkey", "-in", str(key), "-pubout", "-out", str(folder / "pub.pem")], check=True, capture_output=True)
        d = private_key_from_p8(key.read_text())
        message = b"header.claims"
        (folder / "msg").write_bytes(message)
        (folder / "sig").write_bytes(der_signature(sign_es256(message, d)))
        result = subprocess.run([OPENSSL, "dgst", "-sha256", "-verify", str(folder / "pub.pem"), "-signature", str(folder / "sig"),
                                 str(folder / "msg")], capture_output=True, text=True)
        self.assertIn("Verified OK", result.stdout + result.stderr)

    @unittest.skipIf(OPENSSL is None, "openssl not installed")
    def test_client_secret_is_a_jwt_for_apple(self):
        folder = Path(tempfile.mkdtemp())
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(folder / "k.p8")],
                       check=True, capture_output=True)
        client = AppleClient("br.com.firstsoft.musicreader", "TEAMID1234", "KEYID12345", (folder / "k.p8").read_text())
        header, claims, sig = client.client_secret(now=1_800_000_000).split(".")
        pad = lambda s: s + "=" * (-len(s) % 4)  # noqa: E731
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(header))), {"alg": "ES256", "kid": "KEYID12345"})
        c = json.loads(base64.urlsafe_b64decode(pad(claims)))
        self.assertEqual((c["iss"], c["sub"], c["aud"], c["exp"] - c["iat"]),
                         ("TEAMID1234", "br.com.firstsoft.musicreader", "https://appleid.apple.com", 3600))
        self.assertEqual(len(base64.urlsafe_b64decode(pad(sig))), 64)


@unittest.skipIf(OPENSSL is None, "openssl not installed")
class RevocationTests(unittest.TestCase):
    def test_deleting_an_account_revokes_its_apple_token(self):
        folder = Path(tempfile.mkdtemp())
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(folder / "k.p8")],
                       check=True, capture_output=True)
        sent = []

        def fake_apple(url, form):
            sent.append((url, form))
            return {"refresh_token": "apple-refresh-1"} if url.endswith("/token") else {}

        accounts = omr_server.accounts_service
        previous = accounts.apple
        accounts.apple = AppleClient("br.com.firstsoft.musicreader", "TEAMID1234", "KEYID12345", (folder / "k.p8").read_text(), post=fake_apple)
        try:
            status, s = call_json("POST", "/auth/apple", {"identityToken": apple.token(secrets.token_hex(6)), "authorizationCode": "code-1"})
            self.assertEqual(status, 200, s)
            self.assertEqual((sent[0][0], sent[0][1]["code"], sent[0][1]["grant_type"]), (AppleClient.TOKEN_URL, "code-1", "authorization_code"))
            self.assertEqual(call_json("DELETE", "/me", token=s["accessToken"])[0], 204)
            self.assertEqual(sent[-1][0], AppleClient.REVOKE_URL)
            self.assertEqual((sent[-1][1]["token"], sent[-1][1]["token_type_hint"]), ("apple-refresh-1", "refresh_token"))
        finally:
            accounts.apple = previous


if __name__ == "__main__":
    unittest.main()
