"""End-to-end test of the server's API with a fake Audiveris (no Docker or Java needed).

    python3 -m unittest server/test_omr_server.py
"""

import http.client
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp(prefix="omr-test-"))

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
with zipfile.ZipFile(out / (src.stem + ".mxl"), "w") as z:
    z.writestr("META-INF/container.xml", '<container><rootfiles><rootfile full-path="score.xml"/></rootfiles></container>')
    z.writestr("score.xml", "<score-partwise version='4.0'/>")
""")
FAKE.chmod(FAKE.stat().st_mode | stat.S_IEXEC)

os.environ.update(AUDIVERIS_CMD=str(FAKE), OMR_DATA=str(TMP / "data"), OMR_PORT="18765", OMR_TOKEN="secret")
sys.path.insert(0, str(HERE))
import omr_server  # noqa: E402

threading.Thread(target=omr_server.main, daemon=True).start()
# Wait until the server answers (it probes the Audiveris version before listening).
for _ in range(100):
    try:
        http.client.HTTPConnection("localhost", 18765, timeout=1).request("GET", "/health")
        break
    except OSError:
        time.sleep(0.05)


def call(method, path, body=None, headers=None, token="secret"):
    c = http.client.HTTPConnection("localhost", 18765, timeout=10)
    h = dict(headers or {})
    if token:
        h["Authorization"] = f"Bearer {token}"
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    return r.status, r.read()


def wait(job_id):
    for _ in range(50):
        status, body = call("GET", f"/jobs/{job_id}")
        job = json.loads(body)
        if job["status"] in ("done", "failed"):
            return job
        time.sleep(0.1)
    raise AssertionError("job never finished")


class ServerTests(unittest.TestCase):
    def test_health_is_open(self):
        status, body = call("GET", "/health", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["version"], "5.11.0")

    def test_token_required(self):
        self.assertEqual(call("GET", "/jobs/x", token=None)[0], 401)
        self.assertEqual(call("GET", "/jobs/x", token="wrong")[0], 401)

    def test_transcribe_and_download(self):
        status, body = call("POST", "/jobs", b"%PDF-1.4 fake", {"X-Filename": "Suite No. 1.pdf"})
        self.assertEqual(status, 202)
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "done")
        self.assertEqual(job["movements"], 1)
        status, xml = call("GET", f"/jobs/{job['id']}/musicxml")
        self.assertEqual(status, 200)
        self.assertIn(b"score-partwise", xml)
        self.assertEqual(call("DELETE", f"/jobs/{job['id']}")[0], 204)
        self.assertEqual(call("GET", f"/jobs/{job['id']}")[0], 404)

    def test_failure_is_reported(self):
        _, body = call("POST", "/jobs", b"%PDF", {"X-Filename": "bad.pdf"})
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "failed")
        self.assertIn("no staves found", job["error"])

    def test_rejects_other_files(self):
        self.assertEqual(call("POST", "/jobs", b"x", {"X-Filename": "notes.docx"})[0], 415)

    @unittest.skipIf(omr_server.Image is None, "Pillow not installed")
    def test_photos_are_prepared_as_grayscale(self):
        from PIL import Image
        src = TMP / "photo.jpg"
        Image.new("RGB", (40, 20), (200, 180, 150)).save(src)
        prepared = omr_server.prepare_image(src)
        self.assertEqual(prepared.suffix, ".png")
        with Image.open(prepared) as im:
            self.assertEqual(im.mode, "L")
        pdf = TMP / "page.pdf"
        pdf.write_bytes(b"%PDF")
        self.assertEqual(omr_server.prepare_image(pdf), pdf, "PDFs pass through")

    def test_filename_is_sanitised(self):
        self.assertEqual(omr_server.safe_filename("../../etc/pass wd.PDF"), "pass_wd.pdf")


if __name__ == "__main__":
    unittest.main()
