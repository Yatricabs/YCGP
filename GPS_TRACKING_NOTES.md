# GPS Tracking & Billing - Live Notes

**This file is a living document.** Every time something in the GPS
tracking/billing logic is added, changed, or fixed, update the
"Implemented so far" log below with a new dated entry. Every time an
idea comes up that isn't implemented yet, add it to "Not done yet -
future ideas" instead of losing track of it in a chat.

Core files this covers: `lib/gps_validator.dart`,
`lib/ride_persistence.dart`, `lib/event_logger.dart`, and the
GPS-related parts of `lib/main.dart`.

---

## 1. The use case, in one paragraph

YATRI CABS bills intercity rides purely from GPS - no odometer, no
network dependency for the distance calculation itself. Routes commonly
pass through high hill/mountain terrain, dense forest, and other remote
areas with **no mobile network at all - only satellite GPS, and even
that can be weak, noisy, or lost entirely for anywhere from seconds to
several minutes.** Every design decision below exists to keep the
billed distance accurate, fraud-resistant, and crash-safe under those
specific conditions - not under ideal flat-open-urban GPS conditions.

---

## 2. Implemented so far

*(Newest entries at the top. One line each: what, and the one-line why.)*

- **Current + average speed monitoring** - a small speedometer card
  (current speed live, trip-average below) on the map and in the PiP
  view; average speed's elapsed-time reference survives crash-recovery
  so it doesn't reset on an app restart mid-ride.
- **Battery-settings flow rebuilt after a real-device crash** - the
  original OEM-auto-start-launching approach (`disable_battery_
  optimization` plugin) crashed the app on a real Xiaomi/MIUI test
  device; replaced with a manual-instructions dialog (zero native
  Settings-intent launches) plus a persistent orange banner that
  actually verifies the standard exemption is granted and re-checks on
  ride start, every 30s (piggybacked on the GPS watchdog), and on
  app-resume - a real compliance nudge instead of a one-time dialog
  the driver can dismiss and forget.
- **GPS-stream watchdog + driver "don't force-close" warning dialog** -
  the watchdog restarts a silently-stalled stream after 90s of no fix;
  the dialog tells the driver plainly not to force-close the app
  mid-ride, since that's the one failure mode no code can fully
  prevent.
- **Elevation-aware (3D) distance** - flat great-circle distance alone
  under-counts a climb/descent on hill roads; altitude change is
  combined in (clamped against GPS altitude noise).
- **GPS-fix timestamp instead of processing time** - avoids skewing the
  implied-speed check if the app was briefly paused (e.g. PiP resume).
- **Adaptive poll interval (2s ↔ 8s)** - saves battery while the
  vehicle is genuinely stationary; battery is often the real bottleneck
  on a long remote ride.
- **Ride-level sanity net** - flags (doesn't block) if total distance
  ever exceeds 2.5x the pre-trip estimate, catching slow cumulative
  drift no single fix would individually get rejected for.
- **Automatic anomaly/event logging** (`event_logger.dart`) - mock-GPS
  detections, long signal gaps, stream errors, crash-recovery, and
  permission failures are queued locally (network is often unavailable
  exactly when these happen) for later backend sync.
- **Crash-safe local persistence** (`ride_persistence.dart`) - running
  distance/route/last-fix saved after every accepted GPS fix; an
  interrupted ride resumes instead of restarting the bill at zero.
- **GPS-fix validation rewritten for remote/hilly terrain**
  (`gps_validator.dart`) - mock/fake-GPS rejection, implied-average-speed
  check (replacing a fixed max-distance-per-fix that broke on long
  signal gaps), relaxed accuracy threshold (200m), stationary-jitter
  filter using the device's own reported speed.
- **Foreground-service GPS tracking** - survives screen lock and
  incoming calls, which a plain Dart Timer does not.
- **Wakelock + Picture-in-Picture** - screen stays on during a ride;
  app floats instead of fully backgrounding when the driver switches
  apps.
- **Core distance-calculation bug fix** - a `>=3m` movement floor was
  silently discarding normal movement, keeping the bill stuck at 0.0km.

---

## 3. Not done yet - future ideas

*(Nothing here is scheduled - this is a parking lot so a good idea
raised once doesn't get lost. Move an item up to section 2 once it's
actually implemented.)*

- **Backend sync wiring** - `EventLogger.trySync()` and the Kafka/REST
  distance-sync pipeline are both designed for this but not connected -
  no backend endpoint was available yet. Needs the actual API URL/auth
  from the backend team.
- **Spike-and-return double-counting** - a rare case where one bad GPS
  fix jumps away and a second jumps back, each individually looking
  like plausible speed. Needs multi-point sensor fusion (e.g. a Kalman
  filter across several fixes) to fully close - documented as a known
  limitation for now, not yet worth the added complexity unless it
  shows up in real testing.
- **Raw GPS provider option** - `AndroidSettings(forceLocationManager:
  true)` would bypass Google's fused location provider and pull
  straight from the GPS hardware. Worth A/B testing specifically in
  deep-signal-loss zones; fused location's network-assisted fixes might
  be slightly slower to (re)acquire with zero connectivity.
- **Full raw audit log of every fix** - currently only *anomalies* are
  logged (2.10 in README). A complete (accepted + rejected) fix-by-fix
  log would let support fully replay any disputed stretch of a ride,
  at the cost of significantly more local storage.
- **Battery-level-aware polling** - the adaptive 2s/8s polling (section
  2) only reacts to vehicle speed. It could also slow down further when
  the phone's battery is critically low (e.g. <15%), trading a bit of
  billing granularity for not losing tracking entirely to a dead phone.
- **`flutter_background_service`-based architecture** - would run
  tracking as a fully independent native Android service, decoupled
  from the app's UI isolate. Possibly marginally more resilient in some
  edge cases than the current `geolocator` foreground-service approach,
  but adds real complexity (cross-isolate communication). Not
  recommended unless the current approach proves insufficient in real
  testing.
- **Unit tests for `gps_validator.dart`** - the validation logic was
  deliberately split into its own file specifically so it *can* be
  tested in isolation (feed it synthetic `Position` sequences: a signal
  gap, a stationary jitter case, a spike, a mock-GPS fix) - this hasn't
  actually been written yet.
- **iOS support** - everything so far is Android-only (foreground
  service, PiP, OEM battery guidance are all Android concepts). If an
  iOS driver app is ever needed, the GPS-validation and persistence
  logic (`gps_validator.dart`, `ride_persistence.dart`) is
  platform-agnostic and should port directly; the background-tracking
  and reliability layer (2.7/2.11 in README) would need an iOS-specific
  equivalent.
