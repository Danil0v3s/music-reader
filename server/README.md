# Music Reader server

The app's server. It hosts many people, each with a private library:

- **Accounts.** Sign in with Apple, Google, or email and password, or use the app as a guest (an anonymous
  account tied to the device, which keeps everything when it later signs up). Sessions are short-lived access
  tokens renewed with refresh tokens; passwords are scrypt hashes; Apple and Google ID tokens are verified
  against the providers' keys. Deleting an account removes everything in it and revokes Sign in with Apple.
  (`accounts.py`, `idtokens.py`, `apple_tokens.py`)
- **Your library.** Each user's scores, original PDFs and collections, synced across their devices
  (`library_store.py`). Nothing is visible to anyone else.
- **Sharing.** An owner can make a code for a score or a collection; anyone with it can look at the music
  read-only and import their own editable copy. Only notation is shared, never originals. (`shares.py`)
- **Recognition.** It turns PDFs, scans and photos of sheet music into MusicXML using
  [Audiveris](https://github.com/Audiveris/audiveris). Photos are converted to grayscale with the contrast
  stretched first. Small images are enlarged so the staff lines are about 20 px apart (Audiveris gives up
  below about 10); an enlarged image is read at two sizes and the reading with more complete bars wins.
  Every scan is logged with its device and page count (for per-device free scans later).

Everything is in an SQLite database in the data volume (`db.py`, migrations run at startup); original PDFs
are files next to it. Standard library only, plus Pillow for photos. The HTTP API is documented at the top
of `api.py`.

## Run

The image is `linux/amd64`, because Audiveris only ships x86_64 Linux packages.

```
cp server/.env.example server/.env    # then fill it in
docker compose -f server/docker-compose.yml up -d --build
curl http://<host>:8765/health
```

In the app, the server address goes on the sign-in screen (or Settings → Server), e.g. `192.168.1.20:8765`.
The iOS simulator can use `http://localhost:8765` when the container runs on the same Mac.

### On a public address (HTTPS)

Point a domain at the machine, open ports 80 and 443, and set in `.env`: `OMR_DOMAIN`,
`OMR_PUBLIC_URL=https://<domain>` and `OMR_TRUST_PROXY=1`. Then `docker compose --profile public up -d` starts
Caddy in front, which gets and renews the certificate. Remove the `8765` port mapping (or firewall it) so
everything goes through Caddy.

### Sign-in providers and email

| Variable | Default | |
|---|---|---|
| `OMR_APPLE_AUDIENCE` | `br.com.firstsoft.musicreader` | Sign in with Apple: the app's bundle id |
| `OMR_APPLE_TEAM_ID`, `OMR_APPLE_KEY_ID`, `OMR_APPLE_PRIVATE_KEY_FILE` | | A Sign in with Apple key (.p8), to revoke Apple sign-in when an account is deleted (App Store rule) |
| `OMR_GOOGLE_CLIENT_IDS` | empty (off) | Google Sign-In: the iOS OAuth client id; also set `GoogleClientID` in `ios/project.yml` |
| `OMR_SMTP_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `OMR_MAIL_FROM` | | Account emails; without a host they're written to the log |
| `OMR_PUBLIC_URL` | `http://localhost:8765` | Used in email links and share links |

### Capacity and other settings

| Variable | Default | |
|---|---|---|
| `OMR_WORKERS` | `1` | Recognitions at the same time (each can take up to ~4 GB) |
| `OMR_JOBS_PER_USER` | `3` | Recognitions one user can have waiting or running |
| `OMR_MAX_PAGES` | `60` | Pages a PDF may have |
| `OMR_TIMEOUT` | `900` | Seconds before a transcription is abandoned |
| `OMR_KEEP_HOURS` | `24` | Uploaded files of finished jobs are deleted after this |
| `OMR_FINGERINGS` | `0` | `1` also recognises printed fingering digits (unreliable on photos) |
| `AUDIVERIS_VERSION` (build arg) | `5.11.0` | Audiveris release to install |

Sign-in attempts, new accounts and share-code lookups are rate-limited per address.

## Backups

`server/backup.sh` (run nightly from cron on the host) writes a consistent snapshot of the database and the
originals, keeps 14 days, and copies them elsewhere with `BACKUP_REMOTE=user@host:/path`. The script's header
has the restore command; a restore into a fresh volume has been tried.

## Moving a library from before accounts

Before accounts the server kept one library under `/data/library`. It's left in place. The app uploads its
copy when you first sign in; to move the server's copy instead (for example, if no device has it):

```
docker exec <container> python3 omr_server.py import-library you@example.com
```

## Privacy policy and terms

`/privacy` and `/terms` serve `legal/privacy.html` and `legal/terms.html`. They're drafts describing what the
server stores; fill in the operator and contact address before publishing.

## Test

```
cd server && python3 -m unittest
```

The tests run the real HTTP server against a fake Audiveris and stand-ins for Apple's and Google's keys, so
they need neither Docker, Java nor network access. They cover accounts and sessions, token verification,
guests, private libraries, sharing, deletion, backups, recognition and photo preparation.

## Accuracy

Audiveris does well on clean printed scores (publisher or IMSLP PDFs, 300 dpi scans). It does worse on phone
photos, handwriting and dense engraving. Imported scores keep the original PDF so you can compare and fix
notes in the editor.
