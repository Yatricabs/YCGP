# YATRI CABS Reliability and Backup

This release adds crash diagnostics, foreground-service recovery, and an
Android Storage Access Framework backup for an active ride.

## Changes

- Dart and native uncaught errors are captured in the in-app diagnostics log.
- Unexpected service destruction and app removal from recents are recorded.
- A partial wake lock and GPS-stall watchdog improve tracking during calls and
  other transient interruptions.
- Active-ride notifications are explicitly public on the lock screen.
- SharedPreferences remains the fast primary recovery store. A driver-selected
  SAF folder receives a JSON mirror and is used as a fallback after reinstall.

The folder picker requires driver consent. Android revokes the persisted grant
after uninstall, so the folder must be selected again after reinstall.

## Validation

Run `flutter analyze` and `flutter build apk --debug`. Device validation should
also cover screen locking, app removal from recents, a phone call during an
active ride, and the SAF backup/reinstall recovery flow.