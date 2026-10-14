#!/bin/sh
# Schedules the server's nightly backup (03:30) and a health check (every 5 minutes) on this Mac, as launchd
# jobs for the current user. Logs go to ~/music-reader-backups/. Remove with: install-launchd.sh uninstall
set -eu
SOURCE=$(cd "$(dirname "$0")/.." && pwd)
# launchd jobs may not read external volumes (macOS privacy), so the scripts run from a copy in the home folder.
SERVER="$HOME/Library/Application Support/MusicReader"
AGENTS=$HOME/Library/LaunchAgents
LOGS=$HOME/music-reader-backups
mkdir -p "$AGENTS" "$LOGS" "$SERVER"
for job in backup health; do
    launchctl bootout "gui/$(id -u)/br.com.firstsoft.musicreader.$job" 2>/dev/null || true
    rm -f "$AGENTS/br.com.firstsoft.musicreader.$job.plist"
done
[ "${1:-}" = "uninstall" ] && { rm -rf "$SERVER"; echo "Removed."; exit 0; }
cp "$SOURCE/backup.sh" "$SOURCE/healthcheck.sh" "$SERVER/"

cat > "$AGENTS/br.com.firstsoft.musicreader.backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>br.com.firstsoft.musicreader.backup</string>
  <key>ProgramArguments</key><array><string>$SERVER/backup.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>CONTAINER</key><string>mr-omr</string>
    <key>BACKUP_DIR</key><string>$LOGS</string>
  </dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$LOGS/backup.log</string>
  <key>StandardErrorPath</key><string>$LOGS/backup.log</string>
</dict></plist>
PLIST

cat > "$AGENTS/br.com.firstsoft.musicreader.health.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>br.com.firstsoft.musicreader.health</string>
  <key>ProgramArguments</key><array><string>$SERVER/healthcheck.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/health.log</string>
  <key>StandardErrorPath</key><string>$LOGS/health.log</string>
</dict></plist>
PLIST

for job in backup health; do
    plutil -lint "$AGENTS/br.com.firstsoft.musicreader.$job.plist" >/dev/null
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/br.com.firstsoft.musicreader.$job.plist"
done
echo "Scheduled: backup daily at 03:30, health check every 5 minutes. Logs in $LOGS."
