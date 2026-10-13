# OMR server

Turns PDFs or scans of sheet music into MusicXML for the app, using [Audiveris](https://github.com/Audiveris/audiveris)
(open-source optical music recognition). `omr_server.py` is a standard-library Python wrapper. It queues
uploads, runs one Audiveris transcription at a time and serves the result.

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

## Test

```
python3 -m unittest server/test_omr_server.py
```

The test runs the real HTTP server against a fake Audiveris launcher, so it needs neither Docker nor Java.

## Accuracy

Audiveris does well on clean printed scores (publisher or IMSLP PDFs, 300 dpi scans). It does worse on phone
photos, handwriting and dense engraving. Imported scores keep the original PDF so you can compare and fix
notes in the editor.
