## 1.0.5+6 — Standard Gradle Wrapper restoration

- Added `android/gradlew` and `android/gradlew.bat` wrapper entry points.
- CI now generates the official Gradle 8.12 Wrapper JAR, verifies the wrapper, and builds with `./gradlew :app:assembleRelease`.
- Added the official Gradle 8.12 wrapper-JAR checksum reference.
- Kept GPS/FGS, billing, PiP, persistence, and UI behavior unchanged.

## 1.0.4+5 — CI wrapper-path fix

- Removed all GitHub Actions references to `./android/gradlew` because this repository intentionally uses the GitHub-hosted Gradle 8.12 installation and does not contain the Gradle wrapper script.
- CI now verifies the installed Gradle executable with `gradle --version`.
- CI builds with `gradle :app:assembleRelease --no-daemon --stacktrace --console=plain` from the Android project directory.
- Kept the APK verification and branch-specific artifact upload.
- Kept GPS/FGS, billing, PiP, persistence, and OEM-resilience code unchanged.

## 1.0.3+4 — CI release-build hardening

- Updated GitHub Actions to build the Android release with Gradle 8.12
  directly instead of relying on `flutter build apk --release` to discover
  the generated APK.
- Added explicit CI creation of `android/local.properties` with the Flutter
  and Android SDK paths.
- Added explicit APK discovery/verification at
  `android/app/build/outputs/apk/release/app-release.apk`.
- Enabled `dev` and `main` branch automatic builds and branch-specific artifact
  names.
- Kept the Android GPS/FGS, billing, PiP, persistence, and OEM-resilience code
  unchanged.

## 1.0.2+3 — Build/OEM hardening

- Removed the custom `assembleRelease` APK-copy Gradle hook to keep the Android build graph on the standard Flutter/AGP path.
- Kept the native location Foreground Service, notification safety, service health, PiP, task-removal recovery, and existing GPS billing logic unchanged.
- Added explicit release/test notes documenting what was statically verified and what still requires a real Flutter/Android build and physical-device validation.

# Changelog

Every entry explains **what changed** and **why it matters for YATRI
CABS specifically** - intercity rides through hills, dense forest, and
other remote no-network stretches, billed purely from GPS.

---

### v36 - native Android foreground ride service + background resilience
**What:** Added a custom Android `RideTrackingForegroundService` for genuine
active-ride location tracking, with a dedicated low-importance ongoing
notification, Android `location` foreground-service declaration, native GPS
queueing, service-health state, task-removal handling, Flutter/native
MethodChannel + EventChannel communication, active-ride PiP/back behavior,
explicit-close confirmation, OEM background-protection guidance, and initial
ride persistence at ride start. Existing GPS validation/billing remains in
Dart; the native service is a platform tracking layer and the previous Dart
GPS stream remains a fallback only if the native service cannot start.

**Why:** The old plugin-managed foreground service had previously crashed on a
real Xiaomi/MIUI device with `CannotPostForegroundServiceNotificationException:
Bad notification for startForeground`. This version owns the notification and
foreground-service startup path directly so there is no plugin-generated
foreground notification path to debug indirectly. It also keeps the design
policy-aligned: real location work, user-visible notification, active-ride
scope, and a clean stop when the ride ends.

**Documentation:** Updated `README.md`, `GPS_TRACKING_NOTES.md`, and added
`ANDROID_BACKGROUND_ARCHITECTURE.md` with the architecture, permissions, OEM
strategy, recovery model, and field-test matrix.

---

Every entry explains **what changed** and **why it matters for YATRI
CABS specifically** - intercity rides through hills, dense forest, and
other remote no-network stretches, billed purely from GPS.

---

### Missing app launcher icon added
**What:** Added a proper `mipmap/ic_launcher.png` icon at all five
standard Android density buckets (mdpi through xxxhdpi) and set
`android:icon="@mipmap/ic_launcher"` on the `<application>` tag. Also
removed the now-fully-unused `ic_notification.xml` drawable left over
from the removed foreground-service notification (previous entry).
**Why:** This hand-assembled project (built outside `flutter create`)
never had a launcher icon at all - no mipmap resources existed anywhere,
and the manifest didn't reference one. While investigating the
`CannotPostForegroundServiceNotificationException` crash, this was
flagged as a real gap regardless of whether it was the actual cause: any
Android code path that falls back to the app's standard launcher icon
(the OS itself for the home-screen icon, or any plugin's internal
default notification icon) had nothing valid to resolve. Fixing this is
correct Android practice on its own merits, independent of whichever
exact cause is ultimately confirmed for the notification crash.

### Third real-device crash, root cause found: removed the foreground-service notification entirely
**What:** Removed `foregroundNotificationConfig` from
`AndroidSettings` in `_subscribeToPositionStream` - GPS now runs as a
plain (non-foreground) `Geolocator.getPositionStream()` with no
persistent notification. Also removed the now-unused
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, and `WAKE_LOCK`
manifest permissions, and the now-unused `ic_notification.xml`
drawable. Updated `_showKeepAppOpenWarning()`'s wording to honestly
reflect the new trade-off.
**Why:** The exact crash from the two previous entries below
("YATRI CABS keeps stopping") kept recurring even after removing both
suspected causes (the `disable_battery_optimization` plugin, then a
leftover native `MainActivity` intent). A real device's crash report
finally captured the actual exception:
`android.app.RemoteServiceException$CannotPostForegroundServiceNotificationException:
Bad notification for startForeground`. This is thrown by the OS
directly into the app's main thread via a Binder callback - it is **not
a normal catchable exception**, which is exactly why wrapping the
triggering call in try/catch (done in an earlier fix) never stopped the
crash. The notification icon and required `POST_NOTIFICATIONS`
permission were both already correctly in place per the plugin's
documented usage, and it still crashed - pointing to a deeper,
OEM-specific fragility in the plugin's own foreground-service/
notification-building code on this device, not a straightforward
misconfiguration on the app's side. Given a driver-billing app being
completely unusable is a worse outcome than losing guaranteed
screen-lock survival, the foreground service was removed rather than
debugged further inside third-party plugin internals. See
`GPS_TRACKING_NOTES.md` for the safer path if this is revisited.

### Battery-optimization handling simplified back to the standard-only flow
**What:** Removed the entire guidance/verification/banner layer around
battery optimization: the manual-instructions dialog
(`_showBatterySettingsGuide`), the persistent orange reminder banner,
the periodic + on-app-resume re-verification
(`_checkBatteryOptimizationStatus`, piggybacked on the GPS watchdog),
and the `WidgetsBindingObserver` mixin that powered the resume-recheck.
`_requestBatteryOptimizationExemption()` now does exactly one thing:
request the standard Android exemption once, silently, via
`permission_handler`, and stop there.
**Why:** Two separate real-device crashes on the same Xiaomi/MIUI phone
("YATRI CABS keeps stopping") both traced back to this general feature
area - first a plugin's native OEM-settings launcher, then (after
removing that) a leftover native `MainActivity` intent-launch that
turned out to be unrelated to the new Dart flow but kept the same
feature area under suspicion. Rather than risk a third crash chasing
more thorough OEM-specific coverage, the call was made to accept
whatever level of exemption the single standard Android API grants -
"as much as the OEM allows through the normal channel, nothing more" -
and stop building extra layers on top of it. Less thorough, but this
was the recurring source of app-breaking bugs for a driver-billing app;
reliability of the *core* app now matters more than maximizing
battery-optimization compliance specifically.

### Second real-device crash: leftover native battery-optimization intent
**What:** Removed a native `MainActivity.kt` override that auto-launched
`Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` unconditionally
on every `onCreate()`, with no driver-facing context. Also defensively
wrapped `WakelockPlus`/`Floating` (PiP) enable/disable calls in
try-catch as cheap insurance.
**Why:** "YATRI CABS keeps stopping" recurred on a Xiaomi/MIUI device
even after the Dart-side plugin causing the *first* crash (see next
entry below) was removed. This native code was a leftover from an
earlier, purely-native approach to battery-optimization exemption that
should have been deleted when the app moved to the safer Dart-side
`permission_handler` + guided-dialog flow, but wasn't. It fired an
unprompted Settings intent on literally every activity creation and
could race against the Dart-side flow doing the same job properly -
exactly the "auto-launch an OEM settings intent with no context" pattern
already known to be risky on MIUI, just via a different code path this
time.

### Current + average speed monitoring
**What:** A small speedometer card on the map (current speed, live) plus
trip-average speed below it; also shown compactly in the PiP floating
view. Average speed's elapsed-time reference is persisted so it survives
a crash/restart mid-ride.
**Why:** Gives the driver/passenger a live sense of pace on unfamiliar
hill/forest routes, without needing a separate app - and average speed
staying correct across an app restart matters for the same reason
distance-recovery does (2.4): a remote-area crash shouldn't quietly
reset trip stats to zero.

### Real-device crash fix: OEM battery-settings flow rebuilt
**What:** Removed the `disable_battery_optimization` plugin entirely
(it was used to auto-launch OEM-specific "auto-start" settings screens)
and replaced it with a single plain-Flutter dialog that gives the driver
manual instructions instead of launching any Settings intent itself.
Added `_checkBatteryOptimizationStatus` (verifies the standard exemption
is actually granted via `permission_handler`, rather than assuming a
dialog worked) and a persistent orange banner that stays visible on the
ride screen until it's genuinely fixed - re-checked on ride start, every
30s, and on app-resume (`WidgetsBindingObserver`).
**Why:** On a real Xiaomi/MIUI test device, the previous auto-launching
flow crashed the app outright ("YATRI CABS keeps stopping") right after
the driver tapped Continue on the second chained dialog. A crash during
the exact flow meant to *improve* tracking reliability is worse than not
having the flow at all. The new version trades some convenience
(driver opens Settings manually) for zero native-intent crash risk, and
the persistent banner - instead of a one-time dialog easy to dismiss and
forget - keeps nudging compliance since this can't be enforced, only
encouraged.

---

### Gradle build fix
**What:** `assembleRelease` task lookup wrapped in `afterEvaluate {}` in
`android/app/build.gradle.kts`.
**Why:** Without this, the Android build failed outright with
`Task with name 'assembleRelease' not found` - nothing else in the app
matters if it can't be built into an APK at all.

### Build pipeline moved off FlutLab
**What:** Added `.github/workflows/android-build.yml` (GitHub Actions)
and `codemagic.yaml` as build options, independent of FlutLab's own web
build server.
**Why:** FlutLab's build server intermittently failed with a generic,
undiagnosable `Request failed with status code 400`. A driver-billing
app can't depend on a third-party web IDE's uptime to ship fixes.

### Car marker fixed size + shape
**What:** The live-position marker is drawn in code (`dart:ui` Canvas)
as a small top-view sedan, with its on-map size pinned in logical pixels
regardless of screen density.
**Why:** Cosmetic, but a marker that renders oversized or the wrong
shape on some phones erodes driver/passenger trust in the tracking UI.

### Distance calculation actually working
**What:** Fixed a movement-floor bug (`>= 3m` threshold) that was
silently discarding normal walking/driving-speed movement, keeping the
bill stuck at `0.0km`.
**Why:** This is the core billing number. It cannot be wrong in the
direction of under-billing (loses revenue) or over-billing (erodes
driver/passenger trust) for something this basic.

### Background/foreground-service GPS tracking
**What:** Replaced a plain Dart `Timer` polling loop with
`Geolocator.getPositionStream()` running as a genuine Android foreground
service (persistent notification), plus the two-step foreground+
background location permission flow this requires.
**Why:** A plain Timer gets suspended by Android the moment the screen
locks or a call comes in - both routine, frequent events on a multi-hour
intercity drive. Losing tracking every time the driver's phone rings
would make the whole billing system unreliable by design.

### Screen-on (wakelock) + Picture-in-Picture floating window
**What:** `wakelock_plus` keeps the screen from auto-locking during a
ride; the `floating` package shrinks the app into a small floating
window (like Google Maps navigation) instead of fully backgrounding it
when the driver switches to another app.
**Why:** Keeps the ride-tracking screen usable and visible throughout a
long drive without the driver having to babysit screen timeouts, while
still letting them use WhatsApp/Phone/etc. normally mid-ride.

### GPS-fix validation rewritten for remote/hilly terrain
**What:** New `gps_validator.dart` replacing simple distance-only
filtering with: mock/fake-GPS rejection, an implied-average-speed check
(instead of a fixed max-distance-per-fix), a relaxed accuracy threshold,
and a stationary-jitter filter using the device's own reported speed.
**Why:** This is the change this whole rebuild exists for. Intercity
routes go through hill/mountain terrain, dense forest, and other areas
with **no mobile network - only GPS satellite signal, and even that can
be weak or lost for tens of seconds to minutes at a time.** A naive
"add up every fix-to-fix distance" approach either loses real travel
(rejecting a legitimate jump after a signal gap) or bills fake travel
(GPS jitter accumulating during a long roadside stop). Every rule here
maps directly to one of those failure modes - see README section 2.3
for the full breakdown.

### Crash-safe local persistence
**What:** New `ride_persistence.dart` - the running distance, last
coordinate, and route are saved to local storage after every accepted
GPS fix; an interrupted ride resumes from there instead of restarting
the bill at zero.
**Why:** A phone can crash, get killed by an aggressive OEM battery
manager, or run out of battery mid-ride - more likely on a long remote
stretch where the radio works harder and there's no way to quickly
recharge. Without this, that failure loses the *entire* ride's billed
distance, not just a few seconds of it.

### Automatic anomaly/event logging
**What:** New `event_logger.dart` - captures mock-GPS detections, long
signal gaps, stream errors, crash-recovery events, and permission
failures to a local queue, ready to sync to a backend once an endpoint
exists.
**Why:** This app runs mostly unattended, often with no network, exactly
when something unusual happens. Without automatic capture, a billing
dispute or a recurring device problem has no evidence trail to
investigate later.

### Timestamp fix + elevation-aware (3D) distance + adaptive polling +
### ride-level sanity net
**What:** (1) Speed validation now uses the GPS chip's own fix
timestamp instead of app processing time; (2) distance calculation
combines horizontal movement with altitude change (clamped against
noise) instead of ignoring elevation entirely; (3) GPS polling slows
from 2s to 8s while the vehicle is genuinely stationary, and speeds back
up once moving; (4) a one-time warning is logged if total distance ever
exceeds 2.5x the pre-trip estimate.
**Why:** (1) avoids a subtle timing skew after the app resumes from the
PiP floating window; (2) hill roads have real elevation change that flat
distance quietly under-counts; (3) battery is often the real bottleneck
on a long remote ride - if the phone dies, tracking stops entirely; (4)
catches slow, cumulative drift that no single GPS fix would ever
individually get rejected for.

### Background-reliability hardening
**What:** OEM auto-start/manufacturer-battery-restriction settings
guidance (`disable_battery_optimization`), a GPS-stream watchdog that
restarts tracking if no fix arrives for 90+ seconds, and a one-time
driver warning against force-closing the app from recents.
**Why:** Standard Android battery-optimization exemption doesn't cover
OEM-specific background killers (MIUI, ColorOS, FuntouchOS, etc.) that
several popular phone brands ship - these sit entirely outside any
programmatic fix. No app can guarantee it is never killed; this pushes
reliability as high as is realistically achievable and is transparent
with the driver about the one thing that genuinely can't be solved in
code (force-swiping the app away from recents on a restrictive device).
