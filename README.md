# Major Update Blocker

A small macOS app that hides major OS upgrades (for example macOS 15 to 26 or 27) while letting minor updates through. It has one on/off switch with a confirmation prompt.

## What it does

- **Hides major upgrades** with a configuration profile that sets `forceDelayedMajorSoftwareUpdates` and a 90-day deferral in the Restrictions payload (`com.apple.applicationaccess`).
- **Stops newer major installers from running.** A root LaunchDaemon (`--daemon`) checks every 3 seconds for processes inside an `Install macOS*.app` whose version has a higher major number than the Mac's current one, and kills them. This keeps working after Apple's 90-day deferral ends. Same-major and older installers (for example reinstalling your current release) are left alone. Blocks are logged to `/Library/Logs/MajorUpdateBlocker.log`.
- **Hides the red badge** on System Settings when the only pending update is a major one. If a minor update is pending, the badge is left alone. This is done by setting `AttentionPrefBundleIDs` for `com.apple.systempreferences`, which macOS clears and re-sets itself, so the agent re-checks hourly.
- **Runs at login, then quits.** A LaunchAgent starts the app with `--background` at login and hourly. It only opens a window when the profile is missing or about to expire (at day 75); otherwise it exits within seconds.
- **Renews the profile** before the 90-day limit by re-opening it for approval.

## Install

Download `MajorUpdateBlocker-<version>.pkg` from Releases, install it, then open **Major Update Blocker** from Applications and turn the switch on. macOS requires you to approve the profile in System Settings > Privacy & Security > Profiles. Apps cannot install profiles silently on unmanaged Macs.

Build it yourself with `./build.sh` (needs the Xcode command line tools). Set `SIGN_ID` and `PKG_SIGN_ID` to sign with a Developer ID. Remove everything with `sudo ./uninstall.sh`.

## Limits you should know about

- Apple counts the 90-day deferral from each release's date, not from when the profile is installed. A release that is already more than 90 days old (macOS 26 as of late 2025) will not be hidden by the profile, and reinstalling does not restart its clock. New releases are hidden for their first 90 days. After that, macOS may list the upgrade and show reminders again; only the installer blocker still prevents installation.
- The installer blocker is a process-kill guard, not a hard lock. It cannot stop Software Update from listing an upgrade after the deferral ends, and the installer window will close when it is blocked. It only recognises installers inside an `Install macOS*.app`.
- A user-installed profile can be removed by any admin. For a stronger guarantee, deploy the same restrictions through MDM.
- The badge workaround relies on an undocumented Settings preference and may change between macOS releases.

## Testing status

Built on macOS 15. The installer blocker's version logic was tested with fake installers (newer blocked; same, older and disabled left alone) but not against a real macOS upgrade. Profile approval, renewal, and the badge behaviour need testing on your target macOS versions (15 and 26) before wide rollout.

## License

MIT
