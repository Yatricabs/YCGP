# YATRI CABS GPS Billing - Android

An Android Flutter screen that tracks a live intercity ride: shows the
vehicle's position on Google Maps, and calculates the billed distance
purely from GPS coordinates - built to keep working reliably through
hills, forests, and other remote no-network stretches where satellite
GPS is the *only* signal available.

---

## 1. Project structure

```
lib/
  main.dart              - UI + ride lifecycle (screen, buttons, map, state)
  gps_validator.dart      - decides whether a GPS fix should count toward billing
  ride_persistence.dart   - saves/restores ride progress to local storage
  event_logger.dart       - records anomalies locally and queues them for backend sync

android/
  app/src/main/AndroidManifest.xml   - permissions, foreground-service/PiP config
  app/src/main/res/drawable/
    ic_stat_location.xml             - small icon for the active-ride FGS notification
  app/build.gradle.kts               - Gradle build config (SDK versions, signing)

.github/workflows/android-build.yml  - builds a release APK on every push
codemagic.yaml                       - alternative CI build config
CHANGELOG.md                         - version-by-version history: what changed and why
GPS_TRACKING_NOTES.md                - living doc: GPS use-case log + not-done-yet ideas (update every GPS change)
```

The GPS-fix-validation logic and the local-storage logic are each in
their own file (rather than inline in `main.dart`) specifically so they
can be unit-tested and reasoned about independently of the UI - this is
billing logic, and it should be possible to verify it in isolation.

---

## 2. Feature-by-feature: what it does, and why

### 2.1 Live ride tracking screen (`main.dart`)
Standard 4-step ride progress indicator (Initiate Pickup -> Reached
Pickup -> Boarded -> End Ride), an **End Ride** button, a live Google Map
with the vehicle's position, and an **Estimated Km vs Distance Covered**
card. `estimatedKm` is intentionally hard-coded (291 km) - it is a
pre-trip business estimate, not something GPS should ever change.
`Distance Covered` is the only value GPS drives.

### 2.2 Custom car marker (`_generateCarIcon` in `main.dart`)
Drawn entirely in code with `dart:ui` Canvas (no bundled image asset) as
a small top-view sedan silhouette. **Why drawn in code:** avoids
shipping/managing a separate PNG asset, and the size is pinned in
logical pixels (`BitmapDescriptor.bytes(..., width:, height:)`) so it
renders the same physical size on every phone regardless of screen
density - an earlier version omitted this and the marker rendered
oversized on high-density screens.

### 2.3 GPS distance calculation (`gps_validator.dart`)
This is the core billing logic, and it exists specifically because
**intercity routes go through hills, dense forest, and other remote
areas with no mobile network - only GPS satellite signal, and even that
can be weak, noisy, or lost entirely for a while.** A naive
"add up every GPS-to-GPS distance" approach breaks in several ways out
there; each rule below is a direct fix for one:

| Real-world problem | What goes wrong without a fix | How it's handled |
|---|---|---|
| Deep signal loss (tunnels, valleys, dense canopy, mountain ridges) for tens of seconds or minutes | A fixed "GPS arrives every 2 sec" assumption breaks; a large jump after a long gap looks identical to an impossible teleport | Every fix records **wall-clock elapsed time** since the previous one. Distance is validated by **implied average speed** (`distance / real elapsed time`), not by a fixed max-distance-per-fix. A 500 m jump after a 40-second gap is correctly accepted (implied ~45 km/h); the same 500 m jump in 2 seconds (implied ~900 km/h) is correctly rejected. |
| Poor accuracy from satellite signal reflecting off cliffs / blocked by tree canopy | Genuine hill/forest fixes get thrown out by an accuracy filter tuned for flat, open, urban GPS | Accuracy threshold relaxed to reject only fixes worse than **200 m** (was 50-100 m) - permissive enough for rough terrain, still strict enough to catch genuinely bad reflections |
| Vehicle stationary for a long stop (driver break, traffic jam, waiting at a remote checkpoint) | Residual GPS position drift (1-2 m of jitter) accumulates over a long stop into several fake kilometers of billed distance | The device's own **reported speed** (independent of position) is cross-checked: if speed reads near-zero and the position shift is small, it's treated as drift, not travel |
| A single wild "spike" GPS reading (one bad fix far from the real path) | One bad fix adds a large, wrong distance jump to the bill | The **implied-speed check** above also catches this - a spike implies an impossible speed and is rejected, even outside of a signal-gap scenario |
| Fake-GPS / mock-location apps (billing fraud from either side of a ride) | A spoofed location could inflate or deflate the billed distance | Every fix's `isMocked` flag (surfaced by Android/iOS itself) is checked - a mocked fix is rejected outright, and a genuine signal gap simply produces *no* fix at all, never a mocked one |
| Movement smaller than GPS's own noise floor | Sub-meter chip noise while parked could very slowly accumulate | Movements under 1 m are ignored entirely |

**Known limitation (documented, not yet solved):** a rare "spike-and-return"
pattern - one bad fix that jumps away and a second bad fix that jumps
back, where *each individual segment* happens to look like a plausible
speed - is not fully caught by a per-segment check alone. Properly
eliminating this needs multi-point sensor fusion (e.g. a Kalman filter
across several fixes), which is a larger follow-up piece of work if it
turns out to matter in practice.

Every fix's outcome is written to the debug log (`GPS fix: accuracy=...
accepted=... reason=... total=...`) - this is invaluable if a driver or
passenger disputes a bill later; support can see exactly why a given
stretch of GPS data was or wasn't counted.

**Four further refinements, specific to hill/rural intercity routes:**

- **GPS-fix timestamp, not processing time.** Implied-speed validation
  uses `Position.timestamp` (the GPS chip's own fix time) rather than
  `DateTime.now()`. The two can drift apart if the app was briefly
  paused (e.g. resuming from the PiP floating window), which would
  otherwise skew the speed calculation.
- **Elevation-aware (3D) distance.** Flat great-circle distance alone
  quietly under-counts a climb or descent on hill roads. Altitude is
  combined in via `sqrt(horizontal² + altitudeDiff²)`, with the altitude
  change clamped to what a very steep real road (~35% grade) could
  plausibly produce per segment - phone-GPS altitude is noisier than
  lat/lng, so an implausible elevation jump is treated as noise rather
  than billed.
- **Adaptive poll interval for battery life.** `_maybeAdjustPollInterval`
  switches GPS polling from the normal 2-second cadence down to 8
  seconds once the reported speed shows the vehicle is genuinely
  stationary (a long stop/break), and back to 2 seconds once it's moving
  again - with a 15-second cooldown so it doesn't thrash. On a long
  remote ride, battery is often the real bottleneck: if the phone dies,
  tracking stops entirely.
- **Ride-level sanity net.** All the checks above are per-fix. As a
  backstop against slow, cumulative drift that no single fix would ever
  individually get rejected for, if the running total ever exceeds 2.5x
  the pre-trip `estimatedKm`, a `DISTANCE_EXCEEDS_ESTIMATE` warning is
  logged once (see 2.10) for human review - billing isn't blocked, since
  the estimate itself can legitimately be off, but it's flagged.

### 2.4 Crash-safe local persistence (`ride_persistence.dart`)
**Why it exists:** if the app crashes, gets killed by an aggressive OEM
battery manager (common on Xiaomi/Vivo/Oppo/Samsung, and more likely on
long rural stretches where the radio works harder), or the phone's
battery dies mid-ride, the distance billed so far must not be lost.

After **every** GPS fix that counts toward billing, the running total,
the last known coordinate, and the full route are written to the
phone's local storage (`SharedPreferences`). On the next app launch,
`RidePersistence.loadInProgressRide()` checks for an unfinished ride and
resumes counting from there instead of restarting the bill at zero. A
clean "End Ride" tap clears this saved state, since there's nothing left
to recover.

This is the **on-device half** of a larger sync strategy: distance data
still needs to reach the backend. Kafka itself is a server-side message
broker and can't be called directly from a mobile app - the mobile side
should periodically call a **REST/HTTPS API endpoint**, which internally
publishes to Kafka on the backend. That endpoint isn't wired up yet in
this project (no backend URL was available at the time this was built) -
`RidePersistence` is written so a periodic sync call can be added
cleanly once that endpoint exists, without touching the local-storage
logic.

### 2.5 Screen stays on during a ride (`wakelock_plus`)
`WakelockPlus.enable()` is called when the ride starts and
`WakelockPlus.disable()` when it ends (or the screen disposes). Without
this, Android's normal auto-lock would turn the screen off during a long
drive, which - combined with some OEMs' aggressive power-saving - can
also affect how reliably location updates keep arriving.

### 2.6 Picture-in-Picture and active-ride background behavior
During an active ride, Android PiP can shrink the ride UI into a compact
floating window while the native location foreground service continues
independently. `MainActivity.kt` owns PiP behavior; the Flutter `floating`
package remains only for the PiP widget switcher.

**Back behavior:** Android/Flutter Back during an active ride requests PiP
instead of ending or closing the ride. An explicit **Close YATRI CABS** action
uses a confirmation dialog.

**Recents/task removal:** Android does not provide a dependable pre-removal
confirmation hook for an ordinary app. The native service therefore handles
`onTaskRemoved()`, records the event, keeps the ongoing ride notification
visible, vibrates once (best-effort), and continues real location tracking.

### 2.7 Native Android foreground location service
The active ride now uses a custom `RideTrackingForegroundService` rather than
the Geolocator plugin's internal foreground-service notification path. The
service is declared as `foregroundServiceType="location"`, starts only after
a valid location permission and initial ride fix are available, and owns the
Android notification/GPS lifecycle.

The service uses Android `LocationManager` and keeps a lightweight polling
policy: about 2 seconds while moving and about 8 seconds while stationary,
with a cooldown before switching modes. It persists service health and a
bounded queue of GPS fixes so Flutter can recover fixes collected while its
listener is detached.

The previous plugin-managed implementation crashed on a real Xiaomi/MIUI
device with:

```text
CannotPostForegroundServiceNotificationException:
Bad notification for startForeground
```

The custom implementation controls the notification channel, valid bundled
small icon, immutable `PendingIntent`, ongoing notification, and Android
foreground-service type directly. It still does not claim that Android or an
OEM can never stop an app. Extreme memory pressure, Force Stop, shutdown, or
OEM-specific restrictions remain outside an ordinary app's control.

### 2.8 Background service health and recovery
`MainActivity.kt` communicates with the native service through two channels:
`yatri_cabs/ride_service` and `yatri_cabs/ride_events`. Flutter checks native
service health about every 30 seconds during an active ride. Health includes
service-alive state, last GPS timestamp/position, accuracy, speed, status, task
removal time, and pending native fixes.

If the active ride is still marked active but the native service disappears,
Flutter attempts a real foreground-service restart. A long GPS gap is treated
as a signal-loss condition when the service itself is still alive, rather than
as proof of an app kill.

### 2.8a OEM background-protection guidance
YATRI detects the device family and shows driver-facing guidance for Xiaomi/
Redmi/POCO, OPPO, realme, Samsung, OnePlus, vivo, Lava, and generic Android.
The app does not silently launch undocumented OEM Settings intents. This keeps
the reliability layer user-visible and avoids reintroducing the Settings-intent
crash pattern that caused earlier MIUI failures.

A detailed OEM strategy and field-test matrix lives in
`ANDROID_BACKGROUND_ARCHITECTURE.md`.

### 2.9 GPS signal-strength indicator
A small pill in the top-right corner of the map (`GPS: Strong` /
`Moderate` / `Weak` / `Searching...`), driven by
`GpsFixValidator.describeSignal()`. Purely informational - lets the
driver/passenger see when GPS quality has degraded (e.g. entering a
forest stretch) instead of silently wondering why the car marker hasn't
moved.

### 2.10 Automatic anomaly logging (`event_logger.dart`)
**Why it exists:** this is a billing system running mostly unattended in
areas with no network. When something unusual happens, it needs to be
captured automatically rather than silently handled - so a billing
dispute or a recurring device problem can actually be investigated
later, even if nobody was watching the phone at the time.

Six specific situations are logged (deliberately not every routine
low-accuracy rejection, which is common and expected in hills/forest and
would just add noise):

| Code | Severity | When |
|---|---|---|
| `MOCK_GPS_DETECTED` | critical | A fix flagged as fake/mock-location was rejected (fraud signal) |
| `GPS_SIGNAL_GAP` | warning | No fix received for over 60 seconds (tunnel/valley/dense canopy) |
| `POSITION_STREAM_ERROR` | critical | The GPS stream itself threw an error |
| `RIDE_RESUMED_AFTER_RESTART` | warning | App was killed mid-ride and resumed from a recovered distance (device-health signal, not just a one-off) |
| `LOCATION_PERMISSION_DENIED` | warning | Ride couldn't start - permission not granted |
| `INITIAL_GPS_UNAVAILABLE` | critical | Couldn't get a starting GPS fix at all |

Events are queued **locally first** (`SharedPreferences`, capped at 200
entries) - precisely because network is often unavailable exactly when
an event happens (e.g. a signal-loss event, by definition, occurs
somewhere with no signal). `EventLogger.trySync()` is the intended hook
to actually deliver the queue to a backend endpoint once one exists; it
is documented but **not wired up yet** for the same reason as the Kafka
sync in 2.4 - no backend URL was available at the time this was built.
It never clears the local queue before a confirmed successful delivery,
so an event is never silently lost even if a sync attempt fails.

### 2.11 Background reliability - kept deliberately simple after two crashes
**No Android app can guarantee it will *never* be killed** - the OS
reserves the right to kill any process under extreme memory pressure
(this applies to Uber, Ola, Google Maps, and every other app equally,
not just this one), and several OEMs (Xiaomi/MIUI, Oppo/Realme/ColorOS,
Vivo/FuntouchOS, some Samsung builds) ship their own background-app
killers that sit entirely outside standard Android APIs - there is no
code-level way to disable those, only to guide the user to the right
settings screen.

**This area went through two real-device crashes before landing here,
both on the same Xiaomi/MIUI phone ("YATRI CABS keeps stopping"):**
1. The `disable_battery_optimization` plugin's native OEM-specific
   settings launcher crashed the app outright.
2. After removing that, a from-scratch replacement (manual-instructions
   dialog + a persistent verification banner + periodic re-checks via a
   `WidgetsBindingObserver`) was built - but the crash recurred anyway,
   this time traced to an unrelated leftover native
   `MainActivity.onCreate()` override that had nothing to do with the
   new Dart flow but was auto-launching its own unprompted Settings
   intent on every app start (removed - see CHANGELOG).

Given two crashes traced back to this general feature area, the
decision was made to **stop trying to be clever here.** Everything past
the single standard Android exemption request - OEM-specific guidance,
the persistent reminder banner, the periodic/on-resume re-verification -
was removed rather than patched a third time:

- **`_requestBatteryOptimizationExemption()` now does exactly one
  thing:** request the standard Android battery-optimization exemption
  once, silently, via `permission_handler`, right after location
  permission is granted. No dialog, no OEM-specific guidance, no
  verification loop, no banner. Whatever the OEM allows through that one
  standard, well-tested API call is what the app gets - nothing more is
  attempted.
- **`WakelockPlus`/`Floating` (PiP) enable/disable calls are wrapped in
  try-catch** as cheap insurance against native failures on quirky OEM
  builds, even though neither was the actual cause of either crash.
- **GPS-stream watchdog** (`_checkPositionStreamHealth`, unrelated to
  battery settings) still restarts the location stream if no fix has
  arrived for 90+ seconds - a genuine deep-signal-loss stretch is
  harmless to restart into either way, and a `GPS_STREAM_WATCHDOG_
  RESTART` event is logged if it happens often on a particular device.
- **Driver education, not just code.** One thing genuinely cannot be
  solved from the app side: on some OEMs, force-swiping the app away
  from the recent-apps list can still kill even a foreground service.
  A one-time dialog (`_showKeepAppOpenWarning`) tells the driver this
  plainly when a ride starts.

Combined with the crash-safe persistence (2.4), this is the pragmatic
tradeoff: less thorough battery-optimization coverage than the removed
approach aimed for, in exchange for a much smaller, better-understood
risk surface. If OEM-specific battery/auto-start guidance is worth
revisiting later, it should be re-approached carefully (see
`GPS_TRACKING_NOTES.md`) rather than reintroduced wholesale.

### 2.12 Current + average speed monitoring
A small speedometer-style card in the top-left of the map shows
**current speed** (large, updates every fix, from `Position.speed`) and
**trip-average speed** underneath (`averageSpeedKmh` = total distance ÷
elapsed ride time, so it includes stops - the same definition a car's
trip computer typically uses). Also shown compactly in the PiP floating
view alongside distance. Average speed's elapsed-time reference
(`_rideStartTime`) is itself persisted and restored on crash-recovery
(2.4), so it stays correct across an app restart mid-ride rather than
resetting.

---

## 3. Android permissions (`AndroidManifest.xml`) and why each exists

| Permission | Why |
|---|---|
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | GPS access for the active ride |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_LOCATION` | Required for the native Android location foreground service |
| `POST_NOTIFICATIONS` | Driver-visible active-ride foreground-service notification on supported Android versions |
| `VIBRATE` | One short best-effort vibration when Android removes the app task during an active ride |
| `WAKE_LOCK` | Supports the existing screen-on behavior provided by `wakelock_plus` |

`ACCESS_BACKGROUND_LOCATION` is **not** automatically requested by this
version. The location foreground service is started from the visible ride
Activity after location permission has been granted.

**Security note:** `AndroidManifest.xml` also contains the Google Maps
API key. Restrict it in Google Cloud Console (Android app restriction:
package name + SHA-1 fingerprint) so it can't be reused if the key ever
leaks from the repo.

---

## 4. Build the APK (recommended: GitHub Actions)

FlutLab's own web build server can intermittently fail with a generic
`Request failed with status code 400` before Gradle even runs. This project
ships with a GitHub Actions workflow so the Android release build does not
depend on FlutLab's server.

The CI workflow builds `:app:assembleRelease` directly with Gradle 8.12
after Flutter dependencies are resolved. This is intentional: the previous
`flutter build apk --release` path could finish the underlying Gradle work
without allowing Flutter's output-discovery step to find the generated APK,
reporting `Gradle build failed to produce an .apk file`. The workflow now
verifies the real AGP output path before uploading the artifact.

1. Push the project to the **dev** or **main** branch.
2. GitHub Actions runs automatically for both branches (or use **Run workflow**).
3. Open the successful `Build Android APK` run and scroll to **Artifacts**.
4. Download `yatri-cabs-apk-dev` for the dev branch or
   `yatri-cabs-apk-main` for the main branch.

The generated release APK is copied from
`android/app/build/outputs/apk/release/app-release.apk`.

### Alternative: Codemagic
A `codemagic.yaml` is included. Connect the same repo at codemagic.io and
start the configured Android workflow.

## 5. Build configuration reference

- Gradle: 8.12 - Android Gradle Plugin: 8.7.3 - Kotlin: 2.1.0
- Android NDK: 27.0.12077973
- Dart/Flutter: compatible with Flutter 3.32 / Dart 3.8.1
- Key packages: `google_maps_flutter 2.13.1`, `geolocator 14.0.2`,
  `geolocator_android` (transitive), `wakelock_plus ^1.3.2`,
  `floating ^6.0.0`, `shared_preferences ^2.3.3`,
  `permission_handler ^11.3.1`

### Gradle release-build path
The Android Gradle Plugin writes the release APK to
`android/app/build/outputs/apk/release/app-release.apk`. The GitHub Actions
workflow now invokes Gradle 8.12 directly and verifies that exact output before
uploading it. No custom Gradle task hook or APK-copy hook is used.

---

## 6. Current app behavior summary

- `Estimated Km` remains hard-coded at 291 km.
- `Distance Covered` remains GPS-driven and crash-recoverable.
- Existing GPS validation, mock-location rejection, signal-gap handling,
  elevation-aware distance, adaptive polling, and anomaly logging remain the
  billing source of truth.
- An active ride starts a genuine native Android location foreground service
  with a persistent notification.
- Flutter receives native GPS fixes through the EventChannel and feeds them
  into the established Dart validator/billing path.
- Native service health is checked every 30 seconds while a ride is active.
- Back during an active ride goes to PiP; explicit Close uses confirmation.
- Recents task removal is handled by native `onTaskRemoved()` and the service
  continues the active ride where Android permits it.
- A lightweight OEM guidance dialog explains relevant background settings.
- Wakelock keeps the display on during active rides; PiP is optional.

