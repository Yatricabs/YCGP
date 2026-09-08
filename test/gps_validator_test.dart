import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yatri_cabs_gps_billing/gps_validator.dart';

Position fix({
  required double latitude,
  required double longitude,
  required DateTime timestamp,
  double accuracy = 10,
  double altitude = 100,
  double speed = 10,
  bool isMocked = false,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: timestamp,
    accuracy: accuracy,
    altitude: altitude,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
    floor: null,
    isMocked: isMocked,
  );
}

void main() {
  final GpsFixValidator validator = GpsFixValidator();
  final DateTime start = DateTime.utc(2026, 1, 1);

  test('accepts realistic movement', () {
    final GpsFixResult result = validator.evaluate(
      current: fix(
        latitude: 28.6139,
        longitude: 77.2095,
        timestamp: start.add(const Duration(seconds: 10)),
      ),
      previousLat: 28.6130,
      previousLng: 77.2090,
      previousAltitude: 100,
      previousFixTime: start,
    );

    expect(result.countTowardBilling, isTrue);
    expect(result.segmentMeters, greaterThan(1));
  });

  test('rejects mocked, inaccurate, duplicate, and implausible fixes', () {
    final List<GpsFixResult> results = <GpsFixResult>[
      validator.evaluate(
        current: fix(
          latitude: 28.6139,
          longitude: 77.2095,
          timestamp: start.add(const Duration(seconds: 10)),
          isMocked: true,
        ),
        previousLat: 28.6130,
        previousLng: 77.2090,
        previousAltitude: 100,
        previousFixTime: start,
      ),
      validator.evaluate(
        current: fix(
          latitude: 28.6139,
          longitude: 77.2095,
          timestamp: start.add(const Duration(seconds: 10)),
          accuracy: 250,
        ),
        previousLat: 28.6130,
        previousLng: 77.2090,
        previousAltitude: 100,
        previousFixTime: start,
      ),
      validator.evaluate(
        current: fix(
          latitude: 28.6139,
          longitude: 77.2095,
          timestamp: start.add(const Duration(milliseconds: 50)),
        ),
        previousLat: 28.6130,
        previousLng: 77.2090,
        previousAltitude: 100,
        previousFixTime: start,
      ),
      validator.evaluate(
        current: fix(
          latitude: 29.6139,
          longitude: 78.2095,
          timestamp: start.add(const Duration(seconds: 1)),
        ),
        previousLat: 28.6130,
        previousLng: 77.2090,
        previousAltitude: 100,
        previousFixTime: start,
      ),
    ];

    expect(results.every((GpsFixResult result) => !result.countTowardBilling),
        isTrue);
  });

  test('accepts a realistic long signal-gap jump', () {
    final GpsFixResult result = validator.evaluate(
      current: fix(
        latitude: 28.6220,
        longitude: 77.2140,
        timestamp: start.add(const Duration(minutes: 2)),
      ),
      previousLat: 28.6130,
      previousLng: 77.2090,
      previousAltitude: 100,
      previousFixTime: start,
    );

    expect(result.countTowardBilling, isTrue);
  });

  test('ignores stationary GPS drift and describes signal quality', () {
    final GpsFixResult result = validator.evaluate(
      current: fix(
        latitude: 28.61302,
        longitude: 77.20901,
        timestamp: start.add(const Duration(seconds: 10)),
        speed: 0.1,
      ),
      previousLat: 28.6130,
      previousLng: 77.2090,
      previousAltitude: 100,
      previousFixTime: start,
    );

    expect(result.countTowardBilling, isFalse);
    expect(GpsFixValidator.describeSignal(10), 'GPS: Strong');
    expect(GpsFixValidator.describeSignal(50), 'GPS: Moderate');
    expect(GpsFixValidator.describeSignal(150), 'GPS: Weak');
    expect(GpsFixValidator.describeSignal(250), 'GPS: Searching...');
  });
}