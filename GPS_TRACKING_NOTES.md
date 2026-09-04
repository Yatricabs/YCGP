# GPS Tracking & Billing - Live Notes

**Living document:** update this file whenever GPS tracking, ride persistence,
Android background behavior, or the driver recovery path changes.

## CI release build note

GitHub Actions uses Gradle 8.12 directly for the Android release task and
verifies the generated APK at `android/app/build/outputs/apk/release/app-release.apk`.
The Flutter CLI's `Already watching path: .../android` message is not treated as
a release-build success/failure signal; the CI job relies on the Gradle exit code
and explicit APK existence check.


## 1. Use case

YATRI CABS bills intercity rides from GPS. The route can include hills, forest,
tunnels, remote areas, and weak/no mobile-data coverage. Mobile data is not a
prerequisite for calculating distance, but Android background execution must
remain reliable while the driver uses other apps.

## 2. Implemented

### v36 native foreground location service

- Added `RideTrackingForegroundService.kt` as the Android-side location FGS.
- Declared `foregroundServiceType="location"` and the Android 14+ location FGS
  permission in the manifest.
- Starts only from the visible ride Activity after location access is available.
- Uses Android `LocationManager` for genuine GPS updates.
- Moving interval: about 2 seconds.
- Stationary interval: about 8 seconds.
- Polling-mode switch cooldown: 15 seconds.
- Service watchdog state is persisted independently of Flutter UI state.
- `onTaskRemoved()` records task removal and keeps the active ride service alive.
- Native GPS fixes are queued (bounded to 600) while Flutter is detached and are
  replayed when Flutter reconnects.

### v36 persistent ride notification

- Added a dedicated low-importance notification channel: `yatri_active_ride`.
- Added a bundled vector small icon: `ic_stat_location.xml`.
- Notification is ongoing and opens `MainActivity` when tapped.
- Distance, speed, and GPS state are reflected in the notification.
- Notification updates are throttled to roughly once every 5 seconds.
- Notification creation is fully owned by the app rather than delegated to the
  Geolocator plugin's foreground-service implementation.

### v36 Flutter/native bridge

- Added `yatri_cabs/ride_service` MethodChannel.
- Added `yatri_cabs/ride_events` EventChannel.
- Added native service health checks every 30 seconds while a ride is active.
- If the FGS disappears during an active ride, Flutter attempts a real FGS
  restart.
- Native location events are converted into the existing Dart `Position` path,
  so the established GPS validator and billing logic remain in use.
- The existing Dart GPS stream remains as a fallback only if native FGS startup
  fails.

### v36 PiP / Back / task handling

- Active ride can enter Android PiP through `MainActivity`.
- Android back during an active ride requests PiP instead of closing the ride.
- Explicit Close action shows an `Are you sure?` dialog.
- Recents/task removal is handled reactively by the native service; the app does
  not attempt to intercept Android's Close All gesture with a fake confirmation.

### v36 OEM guidance

- Device manufacturer/brand/model are detected at runtime.
- Driver-facing background-protection guidance is tailored for Xiaomi/Redmi/POCO,
  OPPO, realme, Samsung, OnePlus, vivo, Lava, and a generic Android path.
- No undocumented OEM Settings intent is launched automatically.
- No fake keep-alive trigger is used.

### Existing GPS billing rules retained

- Mock/fake GPS fixes are rejected.
- Poor accuracy is rejected according to the existing validator threshold.
- Implied-speed checks handle long signal gaps more safely than a fixed
  max-distance-per-fix rule.
- Stationary/jitter filtering prevents slow GPS noise from becoming billed km.
- Elevation-aware 3D distance remains enabled.
- Distance above 2.5x the estimate is flagged for review, not automatically
  blocked.
- Estimated distance remains hard-coded at 291 KM.

### Existing persistence retained and strengthened

- Ride progress is saved after accepted billing fixes.
- A fresh ride now writes its initial recoverable state immediately at ride start.
- Crash/OS-kill restart can restore distance, last location, timestamps, and route.

## 3. Permissions

Required Android permissions:

- precise/coarse location;
- `FOREGROUND_SERVICE`;
- `FOREGROUND_SERVICE_LOCATION`;
- `POST_NOTIFICATIONS`;
- `VIBRATE`;
- `WAKE_LOCK`.

`ACCESS_BACKGROUND_LOCATION` is not automatically requested by this version.

## 4. Known limitations

- No Android app can be guaranteed to survive a user Force Stop, device shutdown,
extreme memory pressure, or an OEM's hard restriction in every situation.
- OEM background controls differ by device model and OS version.
- Lava requires especially thorough physical-device validation because public
  technical documentation is less consistent.
- A GPS signal gap is not the same as a service failure. A tunnel, valley, or
  canopy can produce a genuine multi-minute gap.
- The Dart fallback stream is intentionally retained so a service-start failure
  degrades to the earlier tracking path instead of making the ride screen dead.
- A complete release build and physical-device test remain required before
  production rollout.

## 5. Production test checklist

1. Start ride while the Activity is visible.
2. Verify the ongoing notification appears immediately.
3. Confirm 2-second-ish updates while moving.
4. Stop movement for a long enough interval and verify the service switches to
   lower-frequency updates.
5. Lock the screen.
6. Switch to another app / enter PiP.
7. Receive a phone call.
8. Remove the app task from Recents.
9. Reopen YATRI and verify ride recovery.
10. End ride and verify the foreground notification/service disappears.
11. Repeat on Xiaomi/Redmi/POCO, OPPO/realme, Samsung, OnePlus, vivo, Lava, and
    at least one low-RAM Android Go-class phone.

## 6. Architecture rule

Never use a fake hidden trigger just to keep Android from killing the app. The
background work must remain directly tied to the active ride and visible to the
user through the ongoing foreground-service notification.
