#!/bin/sh
# Checks the Music Reader server and tells you (a macOS notification, and the log) once when it goes down
# and once when it's back. Run every few minutes (server/macos/install-launchd.sh sets that up).
URL=${HEALTH_URL:-http://localhost:8765/health}
STATE=${HEALTH_STATE:-$HOME/music-reader-backups/.server-down}
mkdir -p "$(dirname "$STATE")"
if curl -fsS --max-time 15 "$URL" >/dev/null 2>&1; then
    if [ -f "$STATE" ]; then
        rm -f "$STATE"
        echo "$(date '+%F %T') server is back"
        osascript -e 'display notification "The server is answering again." with title "Music Reader server is back"' 2>/dev/null || true
    fi
else
    if [ ! -f "$STATE" ]; then
        touch "$STATE"
        echo "$(date '+%F %T') server not answering at $URL"
        osascript -e 'display notification "It isn'"'"'t answering. Check Docker and the mr-omr container." with title "Music Reader server is down"' 2>/dev/null || true
    fi
fi
