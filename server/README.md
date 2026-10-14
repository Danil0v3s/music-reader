# Music Reader server

Your own server for the app. It does two jobs:

- **Recognition.** It turns PDFs, scans and photos of sheet music into MusicXML using
  [Audiveris](https://github.com/Audiveris/audiveris) (open-source optical music recognition). Uploads are
  queued and run one at a time. Photos are converted to grayscale with the contrast stretched first, which
  recognises far more reliably.
- **Small images.** Audiveris needs the staff lines a few pixels apart: it reads best at about 20 px from
  line to line (a 300 dpi scan) and gives up below about 10, which is what a screenshot of a page has. The
  server measures the spacing on each image and enlarges it to about 20 px. Because Audiveris is touchy
  about exact sizes, an enlarged image is read twice (at that size and 25% larger), and the server keeps the
  reading with more bars that add up to the time signature. A reading that finds nothing is retried at twice
  the size. The job status shows what happened under `prepared`.
- **Your library.** It stores scores, their original PDFs and your collections (`library_store.py`). Every
  device syncs with it, so it's also your backup. The data lives in the `omr-data` volume under `/data/library`.

`omr_server.py` uses only the Python standard library, plus Pillow for preparing photos.

## Run

The image is `linux/amd64`, because Audiveris only ships x86_64 Linux packages.

```
docker compose -f server/docker-compose.yml up -d --build
curl http://<host>:8765/health
```

In the app, set the server address under **Settings → Recognition server**, e.g. `http://192.168.1.20:8765`.
The iOS simulator can use `http://localhost:8765` when the container runs on the same Mac.

To require a token, set `OMR_TOKEN` (shell or `server/.env`) and enter the same token in the app.

| Variable | Default | |
|---|---|---|
| `OMR_TOKEN` | unset | Bearer token required on everything except `/health` |
| `OMR_TIMEOUT` | `900` | Seconds before a transcription is abandoned |
| `OMR_KEEP_HOURS` | `24` | Finished jobs are deleted after this |
| `OMR_FINGERINGS` | `0` | `1` also recognises printed fingering digits (unreliable on photos) |
| `AUDIVERIS_VERSION` (build arg) | `5.11.0` | Audiveris release to install |

## API

| | |
|---|---|
| `GET /health` | `{"status":"ok","engine":"audiveris","version":"5.11.0","auth":false,"queued":0}` |
| `POST /jobs` | Body is the raw file, header `X-Filename: name.pdf`. Returns `202` and the job |
| `GET /jobs/<id>` | `{"status":"queued\|running\|done\|failed","error":…,"movements":1,"elapsed":12.3}` |
| `GET /jobs/<id>/musicxml?movement=0` | Uncompressed MusicXML |
| `DELETE /jobs/<id>` | `204` |

Library (writes carry `X-Modified: <unix seconds>`, the client's modification time):

| | |
|---|---|
| `GET /library` | `{"scores":[{"id","modified","deleted","title","composer","original"}],"collections":{"modified"}}` |
| `GET` / `PUT` / `DELETE /library/scores/<uuid>` | The score as the app's JSON. `DELETE` leaves a tombstone so other devices learn about it |
| `GET` / `PUT /library/scores/<uuid>/original` | The imported PDF |
| `GET` / `PUT /library/collections` | The collections document |

Back up the library by copying the volume, e.g.
`docker run --rm -v omr-data:/data -v "$PWD":/backup ubuntu tar czf /backup/music-reader-library.tgz /data/library`.

## Test

```
python3 -m unittest server/test_omr_server.py
```

The tests run the real HTTP server against a fake Audiveris launcher, so they need neither Docker nor Java.
They cover the recognition API, the library endpoints, tombstones and photo preparation.

## Accuracy

Audiveris does well on clean printed scores (publisher or IMSLP PDFs, 300 dpi scans). It does worse on phone
photos, handwriting and dense engraving. Imported scores keep the original PDF so you can compare and fix
notes in the editor.
