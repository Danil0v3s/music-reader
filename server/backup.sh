#!/bin/sh
# Nightly backup of the Music Reader server, run on the host (cron: 30 3 * * * /path/to/server/backup.sh).
#   - a consistent snapshot (database + original PDFs) is written inside the container and copied out
#   - archives older than KEEP_DAYS are removed
#   - with BACKUP_REMOTE set (an rsync destination, e.g. user@nas:/backups/music-reader), copied off the machine
# Restore (tried: 16/16 scores, originals and collections back): stop the server, then, from the archive's folder,
#   docker run --rm -u 0 -v omr-data:/data -v "$PWD":/b music-reader-omr \
#       sh -c "python3 omr_server.py restore /b/<archive> && chown -R omr /data"
set -eu
CONTAINER=${CONTAINER:-mr-omr}
DEST=${BACKUP_DIR:-$HOME/music-reader-backups}
KEEP_DAYS=${KEEP_DAYS:-14}
mkdir -p "$DEST"
archive=$(docker exec "$CONTAINER" python3 omr_server.py backup /data/backups)
docker cp "$CONTAINER:$archive" "$DEST/"
docker exec "$CONTAINER" rm -f "$archive"
find "$DEST" -name 'music-reader-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
if [ -n "${BACKUP_REMOTE:-}" ]; then
    rsync -a "$DEST/" "$BACKUP_REMOTE/"
fi
echo "Backed up to $DEST/$(basename "$archive")"
