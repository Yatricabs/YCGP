import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:yatri_cabs_gps_billing/gps_validator.dart';

Position syntheticFix(int index) {
  return Position(
    latitude: 28.6130 + (index * 0.00001),
    longitude: 77.2090 + (index * 0.00001),
    timestamp: DateTime.utc(2026, 1, 1).add(Duration(seconds: index + 1)),
    accuracy: 10,
    altitude: 100 + (index % 20),
    altitudeAccuracy: 0,
    heading: 45,
    headingAccuracy: 0,
    speed: 12,
    speedAccuracy: 0,
    floor: null,
    isMocked: false,
  );
}

void main() {
  test('processes 50,000 GPS fixes without errors or runaway latency', () {
    final GpsFixValidator validator = GpsFixValidator();
    final Stopwatch stopwatch = Stopwatch()..start();
    double latitude = 28.6130;
    double longitude = 77.2090;
    double altitude = 100;
    DateTime previousTime = DateTime.utc(2026, 1, 1);
    int accepted = 0;

    for (int index = 0; index < 50000; index++) {
      final Position current = syntheticFix(index);
      final GpsFixResult result = validator.evaluate(
        current: current,
        previousLat: latitude,
        previousLng: longitude,
        previousAltitude: altitude,
        previousFixTime: previousTime,
      );
      if (result.countTowardBilling) accepted++;
      latitude = current.latitude;
      longitude = current.longitude;
      altitude = current.altitude;
      previousTime = current.timestamp;
    }
    stopwatch.stop();

    expect(accepted, greaterThan(49000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}