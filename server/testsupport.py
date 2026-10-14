"""What the server tests share: a fake Audiveris, one running server, a request helper, and a stand-in for
Apple's and Google's token signing (an RSA key made here, published as the providers' keys).

    cd server && python3 -m unittest
"""

import base64
import hashlib
import http.client
import json
import os
import secrets
import stat
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="omr-test-"))
PORT = 18765

# The fake launcher writes a compressed .mxl like Audiveris does, or fails for a file named "bad.pdf".
FAKE = TMP / "fake-audiveris"
FAKE.write_text(f"""#!{sys.executable}
import sys, zipfile, pathlib
args = sys.argv[1:]
if "-version" in args:
    print("Audiveris"); print("- Version:      5.11.0"); sys.exit(0)
out = pathlib.Path(args[args.index("-output") + 1]); src = pathlib.Path(args[-1])
if src.name == "bad.pdf":
    print("no staves found"); sys.exit(3)
# Like Audiveris, give up on an image whose staff lines are too close together (here: a PNG under 1000 px wide).
if src.suffix == ".png" and src.name.startswith("small") and int.from_bytes(src.read_bytes()[16:20], "big") < 1000:
    print("Error in export"); sys.exit(1)
measures = ""
if src.suffix == ".png" and src.name.startswith("sized"):
    measures = "<part id='P1'>" + "<measure><note/></measure>" * (int.from_bytes(src.read_bytes()[16:20], "big") // 1000) + "</part>"
with zipfile.ZipFile(out / (src.stem + ".mxl"), "w") as z:
    z.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="score.xml"/></rootfiles></container>')
    z.writestr("score.xml", "<score-partwise version='4.0'>" + measures + "</score-partwise>")
""")
FAKE.chmod(FAKE.stat().st_mode | stat.S_IEXEC)

APPLE_AUD = "br.com.firstsoft.musicreader"
GOOGLE_AUD = "test-client.apps.googleusercontent.com"
os.environ.update(AUDIVERIS_CMD=str(FAKE), OMR_DATA=str(TMP / "data"), OMR_PORT=str(PORT),
                  OMR_APPLE_AUDIENCE=APPLE_AUD, OMR_GOOGLE_CLIENT_IDS=GOOGLE_AUD, OMR_PUBLIC_URL="https://music.test")
os.environ.pop("OMR_SMTP_HOST", None)
sys.path.insert(0, str(HERE))
sys.argv = sys.argv[:1]
import omr_server  # noqa: E402

# --- A stand-in identity provider: RS256 with a key made here -------------------------------------------


def _probable_prime(bits: int) -> int:
    while True:
        n = secrets.randbits(bits) | (1 << (bits - 1)) | 1
        if all(n % p for p in (3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)) and _miller_rabin(n):
            return n


def _miller_rabin(n: int, rounds: int = 24) -> bool:
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(rounds):
        x = pow(secrets.randbelow(n - 3) + 2, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def make_rsa_key(bits: int = 1024) -> tuple[int, int, int]:
    e = 65537
    while True:
        p, q = _probable_prime(bits // 2), _probable_prime(bits // 2)
        phi = (p - 1) * (q - 1)
        if p != q and phi % e:
            return p * q, e, pow(e, -1, phi)


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class FakeProvider:
    """Signs ID tokens like Apple or Google would, with keys only the tests know."""

    def __init__(self, issuer: str, audience: str, kid: str):
        self.issuer, self.audience, self.kid = issuer, audience, kid
        self.n, self.e, self.d = make_rsa_key()

    def jwks(self, url: str = "") -> dict:
        k = (self.n.bit_length() + 7) // 8
        return {"keys": [{"kty": "RSA", "kid": self.kid, "alg": "RS256",
                          "n": b64(self.n.to_bytes(k, "big")), "e": b64(self.e.to_bytes(3, "big"))}]}

    def token(self, sub: str, *, aud: str | None = None, exp: float | None = None, nonce: str | None = None,
              email: str | None = None, tamper: bool = False) -> str:
        header = b64(json.dumps({"alg": "RS256", "kid": self.kid}).encode())
        claims = {"iss": self.issuer, "aud": aud or self.audience, "sub": sub, "iat": int(time.time()),
                  "exp": int(exp if exp is not None else time.time() + 600)}
        if email:
            claims.update(email=email, email_verified=True)
        if nonce:
            claims["nonce"] = hashlib.sha256(nonce.encode()).hexdigest()
        payload = b64(json.dumps(claims).encode())
        k = (self.n.bit_length() + 7) // 8
        digest_info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(f"{header}.{payload}".encode()).digest()
        em = b"\x00\x01" + b"\xff" * (k - len(digest_info) - 3) + b"\x00" + digest_info
        sig = pow(int.from_bytes(em, "big"), self.d, self.n).to_bytes(k, "big")
        if tamper:
            sig = bytes([sig[0] ^ 1]) + sig[1:]
        return f"{header}.{payload}.{b64(sig)}"


apple = FakeProvider("https://appleid.apple.com", APPLE_AUD, "apple-test")
google = FakeProvider("https://accounts.google.com", GOOGLE_AUD, "google-test")

# --- One server for all the tests ---------------------------------------------------------------------------

threading.Thread(target=omr_server.main, daemon=True).start()
for _ in range(200):
    try:
        c = http.client.HTTPConnection("localhost", PORT, timeout=1)
        c.request("GET", "/health")
        c.getresponse().read()
        break
    except OSError:
        time.sleep(0.05)
import api  # noqa: E402  (configured by main)
from idtokens import KeySet  # noqa: E402

api.apple.keys = KeySet("test", fetch=apple.jwks)
api.google.keys = KeySet("test", fetch=google.jwks)
# The tests make many accounts from one address; test_accounts checks the limits on their own.
api.signup_limiter = api.RateLimiter(100000, 1)
api.auth_limiter = api.RateLimiter(100000, 1)
api.share_limiter = api.RateLimiter(100000, 1)


def call(method, path, body=None, headers=None, token=None, device=None):
    """One request; `body` may be bytes or a dict (sent as JSON). Returns (status, body bytes)."""
    c = http.client.HTTPConnection("localhost", PORT, timeout=10)
    h = dict(headers or {})
    if isinstance(body, dict):
        body = json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    if token:
        h["Authorization"] = f"Bearer {token}"
    if device:
        h["X-Device"] = device
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    return r.status, r.read()


def call_json(method, path, body=None, **kw):
    status, data = call(method, path, body, **kw)
    return status, (json.loads(data) if data and data[:1] in b"{[" else data)


def guest(device: str | None = None) -> dict:
    status, data = call_json("POST", "/auth/guest", {}, device=device or secrets.token_hex(8))
    assert status == 200, data
    return data
