"""Sign in with Apple, server side: exchanging the app's authorization code for a refresh token, and revoking
it when the account is deleted (App Store Review Guideline 5.1.1(v) requires the revocation).

Talking to Apple needs a client secret: a JWT signed with ES256 by the Sign in with Apple key from the
Apple Developer account (a .p8 file). Standard library only, so P-256 ECDSA is implemented here: a few
lines of elliptic-curve arithmetic, checked in the tests against OpenSSL.

Configuration (all three, or the exchange and revocation are skipped):
    OMR_APPLE_TEAM_ID           the developer team id (10 characters)
    OMR_APPLE_KEY_ID            the key's id (10 characters)
    OMR_APPLE_PRIVATE_KEY       the .p8 file's contents, or OMR_APPLE_PRIVATE_KEY_FILE: its path
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import time
import urllib.parse
import urllib.request

# NIST P-256 (secp256r1).
P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)


def _add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        m = (3 * x1 * x1 + A) * pow(2 * y1, -1, P) % P
    else:
        m = (y2 - y1) * pow(x2 - x1, -1, P) % P
    x3 = (m * m - x1 - x2) % P
    return x3, (m * (x1 - x3) - y1) % P


def multiply(k: int, point=G):
    result = None
    while k:
        if k & 1:
            result = _add(result, point)
        point = _add(point, point)
        k >>= 1
    return result


def sign_es256(message: bytes, d: int) -> bytes:
    """The JWS ES256 signature (r || s, 32 bytes each) of `message` with private key `d`."""
    z = int.from_bytes(hashlib.sha256(message).digest(), "big")
    while True:
        k = secrets.randbelow(N - 1) + 1
        r = multiply(k)[0] % N
        if r == 0:
            continue
        s = pow(k, -1, N) * (z + r * d) % N
        if s:
            return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def private_key_from_p8(pem: str) -> int:
    """The private scalar of an EC key in PKCS#8 PEM (Apple's .p8). The ECPrivateKey inside holds it as
    INTEGER 1 followed by a 32-byte OCTET STRING."""
    body = re.sub(r"-----[^-]+-----|\s", "", pem)
    der = base64.b64decode(body)
    marker = der.find(b"\x02\x01\x01\x04\x20")
    if marker < 0:
        raise ValueError("not a P-256 private key in PKCS#8 form")
    return int.from_bytes(der[marker + 5:marker + 37], "big")


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class AppleClient:
    TOKEN_URL = "https://appleid.apple.com/auth/token"
    REVOKE_URL = "https://appleid.apple.com/auth/revoke"

    def __init__(self, client_id: str, team_id: str | None, key_id: str | None, private_key: str | None, post=None):
        self.client_id, self.team_id, self.key_id = client_id, team_id, key_id
        self.key = private_key_from_p8(private_key) if private_key else None
        self.post = post or self._post

    @classmethod
    def from_environment(cls, client_id: str) -> "AppleClient":
        key = os.environ.get("OMR_APPLE_PRIVATE_KEY") or None
        path = os.environ.get("OMR_APPLE_PRIVATE_KEY_FILE")
        if not key and path and os.path.exists(path):
            key = open(path).read()
        return cls(client_id, os.environ.get("OMR_APPLE_TEAM_ID") or None, os.environ.get("OMR_APPLE_KEY_ID") or None, key)

    @property
    def configured(self) -> bool:
        return bool(self.client_id and self.team_id and self.key_id and self.key)

    def client_secret(self, now: float | None = None) -> str:
        now = time.time() if now is None else now
        header = _b64(json.dumps({"alg": "ES256", "kid": self.key_id}).encode())
        claims = _b64(json.dumps({"iss": self.team_id, "iat": int(now), "exp": int(now) + 3600,
                                  "aud": "https://appleid.apple.com", "sub": self.client_id}).encode())
        signing_input = f"{header}.{claims}".encode()
        return f"{header}.{claims}.{_b64(sign_es256(signing_input, self.key))}"

    @staticmethod
    def _post(url: str, form: dict) -> dict:
        data = urllib.parse.urlencode(form).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read()
        return json.loads(body) if body else {}

    def exchange_code(self, code: str) -> str | None:
        """The refresh token for an authorization code, or None (not configured, or Apple said no)."""
        if not self.configured or not code:
            return None
        try:
            reply = self.post(self.TOKEN_URL, {"client_id": self.client_id, "client_secret": self.client_secret(),
                                               "code": code, "grant_type": "authorization_code"})
        except OSError as e:
            print(f"Apple token exchange failed: {e}", flush=True)
            return None
        return reply.get("refresh_token")

    def revoke(self, refresh_token: str) -> bool:
        if not self.configured or not refresh_token:
            return False
        try:
            self.post(self.REVOKE_URL, {"client_id": self.client_id, "client_secret": self.client_secret(),
                                        "token": refresh_token, "token_type_hint": "refresh_token"})
            return True
        except OSError as e:
            print(f"Apple token revocation failed: {e}", flush=True)
            return False
