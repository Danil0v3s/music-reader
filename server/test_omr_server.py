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


def staves(width, spacing):
    """A page of empty staves: groups of five 1-2 px lines `spacing` apart, with some notes as blobs."""
    from PIL import Image, ImageDraw
    page = Image.new("L", (width, int(width * 1.4)), 255)
    d = ImageDraw.Draw(page)
    y = spacing * 4
    while y + spacing * 5 < page.height:
        for i in range(5):
            d.rectangle([width // 20, y + i * spacing, width - width // 20, y + i * spacing + (i % 2)], fill=0)
        for x in range(width // 10, width - width // 10, spacing * 4):
            d.ellipse([x, y + spacing, x + spacing * 1.3, y + spacing * 2], fill=0)
        y += spacing * 12
    return page


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
        prepared, info = omr_server.prepare_image(src)
        self.assertEqual(prepared.suffix, ".png")
        with Image.open(prepared) as im:
            self.assertEqual(im.mode, "L")
            self.assertEqual(im.size, (160, 80), "no staff to measure: enlarged by width, at most 4x")
        self.assertEqual(info, {"interline": None, "scale": 4})
        pdf = TMP / "page.pdf"
        pdf.write_bytes(b"%PDF")
        self.assertEqual(omr_server.prepare_image(pdf), (pdf, {}), "PDFs pass through")

    @unittest.skipIf(omr_server.Image is None, "Pillow not installed")
    def test_scale_comes_from_the_staff_spacing(self):
        for spacing, expected in [(7, 20 / 7), (10, 2), (20, 1)]:
            src = TMP / f"staves{spacing}.png"
            staves(2000, spacing).save(src)
            self.assertAlmostEqual(omr_server.estimate_interline(omr_server.Image.open(src)), spacing, delta=0.3)
            prepared, info = omr_server.prepare_image(src)
            self.assertAlmostEqual(info["scale"], expected, delta=0.1)
            with omr_server.Image.open(prepared) as im:
                self.assertAlmostEqual(im.width / 2000, info["scale"], delta=0.01)

    @unittest.skipIf(omr_server.Image is None, "Pillow not installed")
    def test_failed_image_is_retried_larger(self):
        # Spacing 16 needs no enlarging, but this reader wants it wider: the second try at 2x reads.
        buf = __import__("io").BytesIO()
        staves(800, 16).save(buf, "PNG")
        _, body = call("POST", "/jobs", buf.getvalue(), {"X-Filename": "small.png"})
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "done", job.get("error"))
        self.assertEqual(job["prepared"]["scale"], 2)
        self.assertTrue(job["prepared"]["retried"])
        self.assertEqual([r["bars"] for r in job["prepared"]["readings"]], [-1, 0], "first failed, retry read")

    @unittest.skipIf(omr_server.Image is None, "Pillow not installed")
    def test_enlarged_image_keeps_the_better_reading(self):
        # Spacing 10 is enlarged 2x, then read again at 2.5x; this reader finds more music in the larger one.
        buf = __import__("io").BytesIO()
        staves(900, 10).save(buf, "PNG")
        _, body = call("POST", "/jobs", buf.getvalue(), {"X-Filename": "sized.png"})
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "done", job.get("error"))
        self.assertEqual([r["scale"] for r in job["prepared"]["readings"]], [2, 2.5])
        self.assertEqual(job["prepared"]["scale"], 2.5)
        status, xml = call("GET", f"/jobs/{job['id']}/musicxml")
        self.assertIn(b"<measure", xml)

    def test_reading_quality_counts_complete_bars(self):
        note = lambda d, extra="": f"<note>{extra}<pitch><step>D</step><octave>3</octave></pitch><duration>{d}</duration><voice>1</voice></note>"
        xml = ("<score-partwise><part id='P1'>"
               "<measure><attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
               + note(8) + note(8) + note(8, "<chord/>") + "</measure>"     # full (the chord note doesn't add time)
               "<measure>" + note(8) + note(4) + "</measure>"                 # a beat short
               "<measure>" + note(16) + note(2) + "</measure>"                # a speck overfills it
               "</part></score-partwise>")
        path = TMP / "q.xml"
        path.write_text(xml)
        self.assertEqual(omr_server.reading_quality([path]), (1, 3, 7))
        # Without a time signature, the usual bar length is the measure: here two full bars and a short one.
        path.write_text(xml.replace("<time><beats>4</beats><beat-type>4</beat-type></time>", "")
                        .replace(note(8) + note(4), note(8) + note(8)))
        self.assertEqual(omr_server.reading_quality([path]), (2, 3, 7))

    def test_filename_is_sanitised(self):
        self.assertEqual(omr_server.safe_filename("../../etc/pass wd.PDF"), "pass_wd.pdf")


class LibraryTests(unittest.TestCase):
    ID = "6F1C2A1E-0B6A-4C0E-9C7B-6A7A3E8D2F11"

    def listing(self):
        status, body = call("GET", "/library")
        self.assertEqual(status, 200)
        return json.loads(body)

    def entry(self, score_id):
        return next((s for s in self.listing()["scores"] if s["id"] == score_id), None)

    def test_score_round_trip_and_tombstone(self):
        score = json.dumps({"id": self.ID, "title": "Early one morning", "composer": "Trad.", "parts": []}).encode()
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", score, {"X-Modified": "1000.5"})[0], 204)
        entry = self.entry(self.ID)
        self.assertEqual((entry["title"], entry["modified"], entry["deleted"]), ("Early one morning", 1000.5, False))
        status, body = call("GET", f"/library/scores/{self.ID}")
        self.assertEqual((status, json.loads(body)["composer"]), (200, "Trad."))

        self.assertEqual(call("PUT", f"/library/scores/{self.ID}/original", b"%PDF-1.4 x")[0], 204)
        self.assertEqual(self.entry(self.ID)["original"], "pdf")
        self.assertEqual(call("GET", f"/library/scores/{self.ID}/original")[1], b"%PDF-1.4 x")

        self.assertEqual(call("DELETE", f"/library/scores/{self.ID}", headers={"X-Modified": "2000"})[0], 204)
        entry = self.entry(self.ID)
        self.assertTrue(entry["deleted"])
        self.assertEqual(entry["modified"], 2000)
        self.assertEqual(call("GET", f"/library/scores/{self.ID}")[0], 404)
        self.assertEqual(call("GET", f"/library/scores/{self.ID}/original")[0], 404)

    def test_collections_document(self):
        doc = json.dumps({"collections": [{"name": "Book 1"}]}).encode()
        self.assertEqual(call("PUT", "/library/collections", doc, {"X-Modified": "3000"})[0], 204)
        self.assertEqual(self.listing()["collections"]["modified"], 3000)
        self.assertEqual(json.loads(call("GET", "/library/collections")[1])["collections"][0]["name"], "Book 1")

    def test_rejects_bad_input(self):
        self.assertEqual(call("PUT", "/library/scores/not-a-uuid", b"{}", {"X-Modified": "1"})[0], 400)
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", b"[1,2]", {"X-Modified": "1"})[0], 400)
        self.assertEqual(call("PUT", f"/library/scores/{self.ID}", b"{}")[0], 400, "X-Modified is required")
        other = "11111111-2222-3333-4444-555555555555"
        self.assertEqual(call("PUT", f"/library/scores/{other}/original", b"%PDF")[0], 404, "score first")
        self.assertEqual(call("GET", "/library", token=None)[0], 401)


if __name__ == "__main__":
    unittest.main()
