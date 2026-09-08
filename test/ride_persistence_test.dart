import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yatri_cabs_gps_billing/ride_persistence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saves and restores an active ride locally', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final RidePersistence persistence = RidePersistence();
    final DateTime start = DateTime.utc(2026, 1, 1);
    final List<LatLng> route = <LatLng>[
      const LatLng(28.6130, 77.2090),
      const LatLng(28.6140, 77.2100),
    ];

    await persistence.saveProgress(
      totalDistanceMeters: 1234.5,
      previousLat: 28.6140,
      previousLng: 77.2100,
      previousAltitude: 112.0,
      previousFixTime: start.add(const Duration(minutes: 2)),
      rideStartTime: start,
      routePoints: route,
    );

    final RideProgress? restored = await persistence.loadInProgressRide();

    expect(restored, isNotNull);
    expect(restored!.totalDistanceMeters, 1234.5);
    expect(restored.previousLat, 28.6140);
    expect(restored.previousLng, 77.2100);
    expect(restored.routePoints, hasLength(2));
    expect(restored.rideStartTime.millisecondsSinceEpoch,
        start.millisecondsSinceEpoch);
  });

  test('clear removes local recovery state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final RidePersistence persistence = RidePersistence();
    final DateTime now = DateTime.utc(2026, 1, 1);

    await persistence.saveProgress(
      totalDistanceMeters: 10,
      previousLat: 28.6130,
      previousLng: 77.2090,
      previousAltitude: 100,
      previousFixTime: now,
      rideStartTime: now,
      routePoints: const <LatLng>[],
    );
    await persistence.clear();

    expect(await persistence.loadInProgressRide(), isNull);
  });
}
