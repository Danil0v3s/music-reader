"""End-to-end tests of recognition with a fake Audiveris (no Docker or Java needed).

    cd server && python3 -m unittest
"""

import json
import time
import unittest

import threading

from testsupport import TMP, call, guest, omr_server

TOKEN = guest()["accessToken"]


def call_as(method, path, body=None, headers=None, token=None):
    return call(method, path, body, headers, token=token or TOKEN)


def wait(job_id):
    for _ in range(50):
        status, body = call_as("GET", f"/jobs/{job_id}")
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
        status, body = call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["version"], "5.11.0")
        self.assertIn("email", json.loads(body)["providers"])

    def test_session_required(self):
        self.assertEqual(call("GET", "/jobs/x")[0], 401)
        self.assertEqual(call("GET", "/jobs/x", token="wrong")[0], 401)

    def test_transcribe_and_download(self):
        status, body = call_as("POST", "/jobs", b"%PDF-1.4 fake", {"X-Filename": "Suite No. 1.pdf"})
        self.assertEqual(status, 202)
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "done")
        self.assertEqual(job["movements"], 1)
        status, xml = call_as("GET", f"/jobs/{job['id']}/musicxml")
        self.assertEqual(status, 200)
        self.assertIn(b"score-partwise", xml)
        self.assertEqual(call_as("DELETE", f"/jobs/{job['id']}")[0], 204)
        self.assertEqual(call_as("GET", f"/jobs/{job['id']}")[0], 404)

    def test_failure_is_reported(self):
        _, body = call_as("POST", "/jobs", b"%PDF", {"X-Filename": "bad.pdf"})
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "failed")
        self.assertIn("no staves found", job["error"])

    def test_limits(self):
        token = guest()["accessToken"]
        many = b"%PDF-1.4\n" + b"<< /Type /Page >>\n" * (omr_server.MAX_PAGES + 1)
        status, body = call("POST", "/jobs", many, {"X-Filename": "anthology.pdf"}, token=token)
        self.assertEqual((status, json.loads(body)["code"]), (413, "too_many_pages"))
        # Jobs a user has waiting are capped; the queue says how many are ahead.
        held = threading.Event()
        original = omr_server.run_audiveris
        omr_server.run_audiveris = lambda job: held.wait(5)
        try:
            ids = [json.loads(call("POST", "/jobs", b"%PDF-1.4 x", {"X-Filename": f"p{i}.pdf"}, token=token)[1])["id"]
                   for i in range(omr_server.JOBS_PER_USER)]
            status, body = call("POST", "/jobs", b"%PDF-1.4 x", {"X-Filename": "one-more.pdf"}, token=token)
            self.assertEqual((status, json.loads(body)["code"]), (429, "too_many_jobs"))
            last = json.loads(call("GET", f"/jobs/{ids[-1]}", token=token)[1])
            self.assertEqual((last["status"], last["ahead"]), ("queued", omr_server.JOBS_PER_USER - 2))
        finally:
            held.set()
            omr_server.run_audiveris = original
            for i in ids:
                for _ in range(50):
                    if json.loads(call("GET", f"/jobs/{i}", token=token)[1])["status"] in ("done", "failed"):
                        break
                    time.sleep(0.1)

    def test_rejects_other_files(self):
        self.assertEqual(call_as("POST", "/jobs", b"x", {"X-Filename": "notes.docx"})[0], 415)

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
        _, body = call_as("POST", "/jobs", buf.getvalue(), {"X-Filename": "small.png"})
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
        _, body = call_as("POST", "/jobs", buf.getvalue(), {"X-Filename": "sized.png"})
        job = wait(json.loads(body)["id"])
        self.assertEqual(job["status"], "done", job.get("error"))
        self.assertEqual([r["scale"] for r in job["prepared"]["readings"]], [2, 2.5])
        self.assertEqual(job["prepared"]["scale"], 2.5)
        status, xml = call_as("GET", f"/jobs/{job['id']}/musicxml")
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


if __name__ == "__main__":
    unittest.main()
