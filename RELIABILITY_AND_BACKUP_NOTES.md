# YATRI CABS Reliability and Backup

This release adds crash diagnostics, foreground-service recovery, and an
Android Storage Access Framework backup for an active ride.

## Current code organization

- `lib/core/app_constants.dart` owns shared colors and ride configuration.
- `lib/services/native_ride_bridge.dart` owns Flutter/native channel names and
  calls.
- `lib/services/native_diagnostics.dart` imports native crash and service events
  into the shared Dart event log.
- `lib/services/saf_backup_service.dart` wraps the Android Storage Access
  Framework calls used by ride persistence.
- `lib/ride_persistence.dart` owns the two-tier SharedPreferences/SAF ride
  recovery path.
- `lib/main.dart` remains the ride screen and orchestration layer; platform
  channel details and shared constants are no longer embedded there.
- Android platform responsibilities remain under the package
  `com.yatricabs.gpsbilling`: activity bridge, foreground service, SAF manager,
  and application crash handler.

## Changes

- Dart and native uncaught errors are captured in the in-app diagnostics log.
- Unexpected service destruction and app removal from recents are recorded.
- A partial wake lock and GPS-stall watchdog improve tracking during calls and
  other transient interruptions.
- Active-ride notifications are explicitly public on the lock screen.
- SharedPreferences remains the fast primary recovery store. A driver-selected
  SAF folder receives a JSON mirror and is used as a fallback after reinstall.
- Android PiP is configured proactively for home/task switching on Android 12+
  and retains a manual fallback on older supported versions.
- Android 13+ notification permission is requested before starting the ride
  service, and the active ride uses a public notification channel.

The folder picker requires driver consent. Android revokes the persisted grant
after uninstall, so the folder must be selected again after reinstall.

## Validation

Run `flutter analyze`, then `flutter clean`, `flutter pub get`, and
`flutter build apk --release`. Device validation should also cover screen
locking, app removal from recents, a phone call during an active ride, and the
SAF backup/reinstall recovery flow.

The automated suite includes GPS acceptance/rejection cases, timezone-safe
ride persistence recovery and clear tests, plus a 50,000-fix synthetic GPS
stress test to catch runaway latency or state errors under heavy load.
The latest run completed with **7 passed, 0 failed**.