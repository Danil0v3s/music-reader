"""Verifying the ID tokens Sign in with Apple and Google Sign-In hand the app (RS256 JWTs).

Standard library only. An RS256 signature check is one modular exponentiation and a byte comparison
(RSASSA-PKCS1-v1_5, RFC 8017 §8.2.2), so it doesn't need a crypto package. The providers' public keys
come from their JWKS endpoints and are cached; an unknown key id triggers one refetch (keys rotate).

What's checked: signature (the provider's current keys), issuer, audience (our app), expiry (with a little
clock skew), and, for Apple, the nonce the app sent when it started the sign-in.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import threading
import time
import urllib.request
from dataclasses import dataclass

APPLE = {"jwks": "https://appleid.apple.com/auth/keys", "issuers": {"https://appleid.apple.com"}}
GOOGLE = {"jwks": "https://www.googleapis.com/oauth2/v3/certs", "issuers": {"https://accounts.google.com", "accounts.google.com"}}
SKEW = 120  # seconds of clock difference tolerated
# DER prefix of a SHA-256 DigestInfo (RFC 8017 §9.2, note 1).
SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


class TokenError(Exception):
    pass


@dataclass
class Claims:
    subject: str
    email: str | None
    email_verified: bool
    name: str
    raw: dict


def b64url(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def verify_rs256(signing_input: bytes, signature: bytes, n: int, e: int) -> bool:
    k = (n.bit_length() + 7) // 8
    if len(signature) != k:
        return False
    s = int.from_bytes(signature, "big")
    if s >= n:
        return False
    em = pow(s, e, n).to_bytes(k, "big")
    digest_info = SHA256_DIGEST_INFO + hashlib.sha256(signing_input).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(digest_info) - 3) + b"\x00" + digest_info
    return hmac.compare_digest(em, expected)


class KeySet:
    """A provider's public keys by key id, fetched from its JWKS URL and refreshed every few hours (or
    straight away for an unknown key id, at most once a minute)."""

    def __init__(self, url: str, fetch=None):
        self.url = url
        self.fetch = fetch or self._fetch
        self.keys: dict[str, tuple[int, int]] = {}
        self.fetched = 0.0
        self.lock = threading.Lock()

    @staticmethod
    def _fetch(url: str) -> dict:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)

    def _refresh(self) -> None:
        doc = self.fetch(self.url)
        keys = {}
        for k in doc.get("keys", []):
            if k.get("kty") == "RSA" and k.get("kid"):
                keys[k["kid"]] = (int.from_bytes(b64url(k["n"]), "big"), int.from_bytes(b64url(k["e"]), "big"))
        self.keys = keys
        self.fetched = time.time()

    def get(self, kid: str) -> tuple[int, int]:
        with self.lock:
            age = time.time() - self.fetched
            if not self.keys or age > 6 * 3600 or (kid not in self.keys and age > 60):
                try:
                    self._refresh()
                except OSError as e:
                    if not self.keys:
                        raise TokenError(f"couldn't fetch the provider's keys: {e}") from e
            if kid not in self.keys:
                raise TokenError("token signed with an unknown key")
            return self.keys[kid]


class Verifier:
    def __init__(self, provider: dict, audiences: set[str], keys: KeySet | None = None):
        self.issuers = provider["issuers"]
        self.audiences = audiences
        self.keys = keys or KeySet(provider["jwks"])

    def verify(self, token: str, nonce: str | None = None, now: float | None = None) -> Claims:
        if not self.audiences:
            raise TokenError("this sign-in method isn't configured on the server")
        try:
            header_b64, payload_b64, sig_b64 = token.split(".")
            header = json.loads(b64url(header_b64))
            payload = json.loads(b64url(payload_b64))
            signature = b64url(sig_b64)
        except (ValueError, json.JSONDecodeError) as e:
            raise TokenError("malformed token") from e
        if header.get("alg") != "RS256":
            raise TokenError("unexpected signing algorithm")
        n, e = self.keys.get(str(header.get("kid", "")))
        if not verify_rs256(f"{header_b64}.{payload_b64}".encode(), signature, n, e):
            raise TokenError("bad signature")
        now = time.time() if now is None else now
        if payload.get("iss") not in self.issuers:
            raise TokenError("wrong issuer")
        aud = payload.get("aud")
        if not (aud in self.audiences if isinstance(aud, str) else any(a in self.audiences for a in aud or [])):
            raise TokenError("token is for another app")
        if float(payload.get("exp", 0)) < now - SKEW:
            raise TokenError("token expired")
        if nonce is not None:
            # Apple puts SHA-256(nonce) in the token; the app sent the nonce itself.
            expected = hashlib.sha256(nonce.encode()).hexdigest()
            if not hmac.compare_digest(str(payload.get("nonce", "")), expected):
                raise TokenError("nonce mismatch")
        if not payload.get("sub"):
            raise TokenError("token has no subject")
        verified = payload.get("email_verified")
        return Claims(subject=str(payload["sub"]), email=payload.get("email"),
                      email_verified=verified is True or verified == "true",
                      name=str(payload.get("name", "")), raw=payload)
