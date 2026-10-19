#!/bin/bash
# Removes Major Update Blocker completely. Run with: sudo ./uninstall.sh
set -u
[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }

PLIST="/Library/LaunchAgents/org.majorupdateblocker.plist"
DAEMON="/Library/LaunchDaemons/org.majorupdateblocker.daemon.plist"
UID_CONSOLE=$(/usr/bin/stat -f %u /dev/console)

/bin/launchctl bootout "gui/$UID_CONSOLE" "$PLIST" 2>/dev/null
/bin/launchctl bootout system "$DAEMON" 2>/dev/null
/usr/bin/profiles remove -identifier org.majorupdateblocker.profile 2>/dev/null
# Restore the Settings badge if the app had hidden it.
sudo -u "#$UID_CONSOLE" /usr/bin/defaults delete com.apple.systempreferences AttentionPrefBundleIDs 2>/dev/null

rm -f "$PLIST" "$DAEMON" /Library/Logs/MajorUpdateBlocker.log
rm -rf "/Applications/Major Update Blocker.app" "/Library/Application Support/MajorUpdateBlocker"
/usr/sbin/pkgutil --forget org.majorupdateblocker.pkg 2>/dev/null
echo "Removed. If the profile is still listed, remove it in System Settings > Privacy & Security > Profiles."
