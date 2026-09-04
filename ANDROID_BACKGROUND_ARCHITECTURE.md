# YATRI CABS Android Background Ride Architecture

## Purpose

YATRI CABS is an intercity driver application whose active ride distance is
calculated from GPS. During a ride the driver may switch apps, use Android
Picture-in-Picture (PiP), receive calls, or pass through areas with little or
no mobile data service. The app therefore uses a **real Android location
Foreground Service (FGS)** as the Android-side runtime for an active ride.

The service is user-beneficial and ride-scoped: it starts when an active ride
is started, displays an ongoing notification, consumes real GPS locations, and
stops when the driver ends the ride.

## Architecture

```text
Driver starts active ride in visible Flutter Activity
                         |
                         v
              MainActivity MethodChannel
                         |
                         v
          RideTrackingForegroundService
             |            |            |
             v            v            v
        GPS location  Ongoing FGS   Health state
             |         notification       |
             +------------+---------------+
                          v
                   Flutter EventChannel
                          |
                          v
             Existing GPS validation engine
                          |
                +---------+---------+
                |                   |
                v                   v
          Distance/billing      Route/UI
                |
                v
        RidePersistence (local)
```

## Android-side responsibilities

`RideTrackingForegroundService.kt` is intentionally limited to platform work:

- starts as a `location` foreground service;
- builds and maintains the active-ride notification;
- receives GPS updates from Android `LocationManager`;
- uses a 2 second moving / 8 second stationary polling policy;
- records service health and the last GPS fix in native SharedPreferences;
- keeps a bounded queue of GPS fixes while Flutter is not attached;
- broadcasts location/service events to Flutter when the Flutter listener exists;
- records `onTaskRemoved()` and keeps the service alive for the active ride;
- gives one short, best-effort vibration after a task-removal event;
- stops location updates and foreground status when the ride ends.

The service does **not** calculate billed distance. Billing validation remains in
the existing Dart engine so the v35 business rules remain the source of truth.

## Flutter/native communication

`MainActivity.kt` exposes:

| Method | Purpose |
|---|---|
| `startRideService` | Start the location FGS from the visible ride Activity |
| `stopRideService` | Stop the ride service |
| `getServiceHealth` | Read service state and last-fix information |
| `drainQueuedLocations` | Recover native GPS fixes collected while Flutter was detached |
| `updateNotification` | Update distance/speed/status shown by the persistent notification |
| `getDeviceProfile` | Read manufacturer/brand/model for OEM guidance |
| `enterPip` | Enter Android PiP during an active ride |
| `closeTask` | Remove the Activity task while leaving an active FGS running |

`ride_events` is an EventChannel carrying location and service events.

## Foreground-service startup safety

The previous v35-era failure was:

```text
CannotPostForegroundServiceNotificationException:
Bad notification for startForeground
```

The custom service deliberately controls the full notification path instead of
handing foreground-service notification creation to a third-party plugin.

Before `startForeground` it:

1. creates the notification channel on Android O+;
2. uses a bundled, valid `@drawable/ic_stat_location` small icon;
3. creates an immutable `PendingIntent` back to `MainActivity`;
4. marks the notification ongoing and low-importance;
5. declares `foregroundServiceType="location"` in the manifest;
6. requests the Android location foreground-service permission;
7. catches setup failures locally and stops the service cleanly rather than
   continuing in a partially-started state.

A complete APK build still has to be performed in Flutter/Android CI or on a
development machine with the project's configured Flutter SDK and Android SDK.
This repository change has been statically checked in the working container;
that is not a substitute for a device build/test.

## Permissions

The manifest now contains:

- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`
- `POST_NOTIFICATIONS`
- `VIBRATE`
- `WAKE_LOCK`

The app does **not** automatically request `ACCESS_BACKGROUND_LOCATION`.
The location FGS is started from the visible ride Activity after location access
has already been granted.

## PiP and Back behavior

The active ride and the background service are separate from the UI state.
During an active ride:

- Android PiP can minimize the UI;
- the location FGS continues independently;
- the Android back path requests PiP instead of closing the active ride;
- a menu entry exposes explicit PiP, background-protection guidance, and a
  close action;
- explicit close shows a confirmation dialog before the Activity task is
  removed.

When the driver uses Recents/task removal, Android does not provide a reliable
pre-emptive confirmation hook for ordinary apps. `onTaskRemoved()` therefore
acts as the reactive safety layer: the service records the event, keeps the
ride notification visible, and preserves location tracking while the active
ride remains marked as active.

## Service health and recovery

The Flutter watchdog checks the native service every 30 seconds.

The health model includes:

```text
active
serviceAlive
serviceStartedAt
lastFixAt
lastLat / lastLng
lastAccuracy
lastSpeedMps
status
lastTaskRemovedAt
queuedFixCount
```

If the service disappears while the ride is active, Flutter attempts a genuine
service restart. If a GPS signal is missing but the service remains alive, that
is treated as a signal-gap condition rather than as proof that the service was
killed.

The Dart ride state is also persisted immediately when a ride begins and after
every accepted GPS segment. This gives crash/restart recovery without relying
on the presence of a network connection.

## OEM strategy

OEM battery managers can still impose restrictions beyond the normal Android
process-priority model. YATRI therefore provides device-family guidance based
on the detected manufacturer/brand, without silently launching undocumented
OEM Settings intents.

### Xiaomi / Redmi / POCO

Keep YATRI unrestricted for battery use, allow Background Autostart where
available, and avoid locking/force-stopping the app during an active ride.

### OPPO / ColorOS

Allow foreground/background activity and auto-launch where the device exposes
those controls.

### realme UI

Allow foreground activity, background activity, and auto-launch where
available.

### Samsung One UI

Avoid placing YATRI in Sleeping or Deep Sleeping apps; Never auto sleeping may
be appropriate for drivers who need long active rides.

### OnePlus / OxygenOS

Avoid restrictive battery optimization during active rides and keep background
activity allowed.

### vivo / Funtouch OS

Allow normal background activity and available auto-start/background-power
permissions during active rides.

### Lava

Treat the device/model as requiring physical validation because a single
current OEM-wide behavior cannot safely be inferred from limited public
technical documentation.

## Deliberately not implemented

No fake or hidden keep-alive mechanisms are used:

- no ghost taps or simulated touch events;
- no invisible Activity used as a keep-alive trick;
- no dummy network requests;
- no infinite CPU loop;
- no fake GPS data;
- no unrelated periodic job used only to fool process management.

The only background work is directly connected to the active ride:
location tracking, ride-state persistence, service health, and the user-visible
ride notification.

## Field-test matrix

The final release should be tested on real devices, not only an emulator:

| Family | Test focus |
|---|---|
| Xiaomi / Redmi / POCO | screen off, battery saver, Recents removal, long ride |
| OPPO | background activity, auto-launch, screen lock |
| realme | background activity, auto-launch, Recents |
| OnePlus | battery optimization, screen lock, long ride |
| Samsung | sleeping/deep-sleep state, screen lock |
| vivo | background power controls, screen lock |
| Lava | model-specific behavior, long ride |
| Android Go / low-RAM | memory pressure, long ride, map minimized |

Every test should verify the same invariant:

> **Active ride + service notification + real GPS work = distance tracking continues.**

## Build and device-validation status

The source package has been statically inspected in the working environment.
The environment used for this packaging pass does not contain the Flutter SDK,
Android SDK/ADB, or a connected physical Android device, so a release APK and
OEM field test cannot honestly be marked as executed here. The repository contains GitHub Actions/Codemagic build definitions for the
real Flutter/Android build. GitHub Actions uses the direct Gradle release path
described in README.md.

Required final validation sequence:

1. `flutter pub get`
2. `flutter analyze`
3. `gradle :app:assembleRelease` (or the included GitHub Actions workflow)
4. Install the release APK on representative Xiaomi/Redmi/POCO, OPPO/realme,
   Samsung, OnePlus, vivo, and Lava/Android Go devices.
5. Execute the active-ride test matrix in this document, including screen-off,
   PiP, Back, Recents/task removal, GPS signal loss, service restart, and End Ride.
