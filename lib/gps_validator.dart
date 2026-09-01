import 'package:geolocator/geolocator.dart';

/// Decides whether a newly-received GPS fix should be counted toward the
/// ride's billed distance.
///
/// WHY THIS EXISTS:
/// YATRI CABS runs intercity rides that can pass through hill/mountain
/// terrain, dense forest, and other remote areas with no mobile network -
/// only satellite GPS is available there, and even that can be weak,
/// noisy, or briefly lost entirely. Billing distance has to stay accurate
/// (and fraud-resistant) through all of that, without needing internet at
/// all. Each rule below maps to a specific real-world failure mode:
///
///  - Fake/mock GPS apps (fraud risk from either side of a ride)
///  - Poor accuracy from satellite reflection off cliffs / canopy blocking
///  - Long signal-loss gaps (a fixed "one fix every 2 sec" assumption
///    breaks down here - a gap of 30-60+ sec is normal in deep terrain)
///  - GPS position jitter while the vehicle is genuinely stationary
///    (a long roadside stop, a traffic jam) - must not silently bill km
///  - Single wild "spike" fixes (one bad reading far from the real path)
class GpsFixValidator {
  /// A fix this poor is more likely reflection/multipath noise than a
  /// real reading - even accounting for hills/forest being worse than
  /// open, flat, urban terrain. Rejected fixes are still shown on the
  /// map (so the driver isn't staring at a frozen dot) but never billed.
  static const double maxAcceptableAccuracyMeters = 200;

  /// No real intercity vehicle exceeds this. Used both to reject GPS
  /// "teleport" spikes AND to correctly accept a large jump after a long
  /// signal gap, as long as the *average* speed implied by the gap is
  /// still realistic (this replaces an older fixed "max 400 m per fix"
  /// rule, which incorrectly rejected genuine travel whenever a signal
  /// gap was longer than the assumed 2-second cadence).
  static const double maxPlausibleSpeedMetersPerSecond = 55; // ~198 km/h

  /// Below this reported speed, the vehicle is treated as stopped -
  /// residual GPS drift while stationary must not add to the bill.
  static const double stationarySpeedThresholdMps = 0.5; // ~1.8 km/h

  GpsFixResult evaluate({
    required Position current,
    required double previousLat,
    required double previousLng,
    required DateTime previousFixTime,
  }) {
    // Fraud protection: Android/iOS both flag positions coming from a
    // mock-location provider (fake-GPS apps). Reject outright - a real
    // signal-loss gap produces NO fix at all, never a mocked one.
    if (current.isMocked) {
      return const GpsFixResult(
        countTowardBilling: false,
        reason: 'Rejected: mock/fake GPS location detected',
      );
    }

    if (current.accuracy > maxAcceptableAccuracyMeters) {
      return GpsFixResult(
        countTowardBilling: false,
        reason:
            'Rejected: accuracy too poor (${current.accuracy.toStringAsFixed(0)} m)',
      );
    }

    final double segmentMeters = Geolocator.distanceBetween(
      previousLat,
      previousLng,
      current.latitude,
      current.longitude,
    );

    final double elapsedSeconds =
        DateTime.now().difference(previousFixTime).inMilliseconds / 1000.0;

    if (elapsedSeconds <= 0.1) {
      // Guards against a divide-by-zero / duplicate fix delivered twice.
      return const GpsFixResult(
        countTowardBilling: false,
        reason: 'Rejected: fix arrived too soon after the previous one',
      );
    }

    // The device's own speed reading is a second, independent signal -
    // it catches "vehicle stationary, GPS drifting" cases that a pure
    // distance/time check can miss (e.g. a driver on a long break where
    // the drift happens to average out to a plausible low speed anyway).
    final bool reportedAsStationary =
        current.speed >= 0 && current.speed < stationarySpeedThresholdMps;
    if (reportedAsStationary && segmentMeters < 5) {
      return const GpsFixResult(
        countTowardBilling: false,
        reason: 'Ignored: vehicle stationary, GPS drift only',
      );
    }

    final double impliedSpeedMps = segmentMeters / elapsedSeconds;
    if (impliedSpeedMps > maxPlausibleSpeedMetersPerSecond) {
      return GpsFixResult(
        countTowardBilling: false,
        reason: 'Rejected: implausible speed '
            '(${(impliedSpeedMps * 3.6).toStringAsFixed(0)} km/h) - '
            'likely a GPS spike, not real movement',
      );
    }

    if (segmentMeters < 1) {
      return const GpsFixResult(
        countTowardBilling: false,
        reason: 'Ignored: movement below GPS noise floor',
      );
    }

    return GpsFixResult(
      countTowardBilling: true,
      segmentMeters: segmentMeters,
    );
  }

  /// Rough signal-quality label for the on-screen indicator.
  static String describeSignal(double accuracyMeters) {
    if (accuracyMeters <= 20) return 'GPS: Strong';
    if (accuracyMeters <= 75) return 'GPS: Moderate';
    if (accuracyMeters <= maxAcceptableAccuracyMeters) return 'GPS: Weak';
    return 'GPS: Searching...';
  }
}

/// Result of evaluating one GPS fix.
class GpsFixResult {
  const GpsFixResult({
    required this.countTowardBilling,
    this.segmentMeters = 0,
    this.reason,
  });

  final bool countTowardBilling;
  final double segmentMeters;

  /// Human-readable reason, mainly for the debug log - not shown in the
  /// UI, but invaluable when a driver disputes a bill and support needs
  /// to see exactly why a stretch of GPS data was/wasn't counted.
  final String? reason;
}
