import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saves and restores in-progress ride state to the device's local
/// storage (SharedPreferences).
///
/// WHY THIS EXISTS:
/// Intercity rides often pass through remote hill/forest stretches with
/// no mobile network and only satellite GPS. If the app crashes, gets
/// killed by the OS (aggressive battery managers on Xiaomi/Vivo/Oppo/
/// Samsung), or the phone runs out of battery mid-ride, the billed
/// distance calculated so far must NOT be lost. Every accepted GPS fix is
/// written here immediately, so at most the last couple of seconds of
/// travel are ever at risk - never the whole ride.
///
/// This is the on-device half of a larger sync strategy: the operations
/// team also periodically pushes this same data to the backend (via a
/// REST endpoint that publishes to Kafka on the server side - a mobile
/// app cannot talk to Kafka directly). Wire that call inside
/// [RideProgress] consumers / a periodic sync task once the backend
/// endpoint is available; this class only guarantees the data survives
/// on the phone itself in the meantime.
class RidePersistence {
  static const String _keyActive = 'ride_active';
  static const String _keyTotalDistance = 'ride_total_distance_m';
  static const String _keyPrevLat = 'ride_prev_lat';
  static const String _keyPrevLng = 'ride_prev_lng';
  static const String _keyRoutePoints = 'ride_route_points';

  /// Called after every GPS fix that counts toward billing. Cheap enough
  /// (SharedPreferences is backed by an in-memory cache + async disk
  /// flush) to call this often without hurting UI performance.
  Future<void> saveProgress({
    required double totalDistanceMeters,
    required double previousLat,
    required double previousLng,
    required List<LatLng> routePoints,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyActive, true);
    await prefs.setDouble(_keyTotalDistance, totalDistanceMeters);
    await prefs.setDouble(_keyPrevLat, previousLat);
    await prefs.setDouble(_keyPrevLng, previousLng);
    await prefs.setString(_keyRoutePoints, _encodeRoute(routePoints));
  }

  /// Called once when the app starts. If a ride was left running (app was
  /// killed instead of the driver tapping "End Ride"), this returns
  /// everything needed to resume exactly where tracking stopped.
  Future<RideProgress?> loadInProgressRide() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool active = prefs.getBool(_keyActive) ?? false;
    if (!active) return null;

    final double? totalDistance = prefs.getDouble(_keyTotalDistance);
    final double? prevLat = prefs.getDouble(_keyPrevLat);
    final double? prevLng = prefs.getDouble(_keyPrevLng);
    if (totalDistance == null || prevLat == null || prevLng == null) {
      return null;
    }

    return RideProgress(
      totalDistanceMeters: totalDistance,
      previousLat: prevLat,
      previousLng: prevLng,
      routePoints: _decodeRoute(prefs.getString(_keyRoutePoints)),
    );
  }

  /// Called when the driver taps "End Ride" normally - the ride finished
  /// cleanly, so there's nothing left to recover.
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyActive);
    await prefs.remove(_keyTotalDistance);
    await prefs.remove(_keyPrevLat);
    await prefs.remove(_keyPrevLng);
    await prefs.remove(_keyRoutePoints);
  }

  String _encodeRoute(List<LatLng> points) {
    return jsonEncode(
      points.map((LatLng p) => <double>[p.latitude, p.longitude]).toList(),
    );
  }

  List<LatLng> _decodeRoute(String? raw) {
    if (raw == null || raw.isEmpty) return <LatLng>[];
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (dynamic e) => LatLng(
              (e as List<dynamic>)[0] as double,
              e[1] as double,
            ),
          )
          .toList();
    } catch (_) {
      // Corrupted/old-format data - safer to drop it than crash on resume.
      return <LatLng>[];
    }
  }
}

/// A previously in-progress ride, restored from local storage after an
/// app crash / OS kill / dead battery.
class RideProgress {
  const RideProgress({
    required this.totalDistanceMeters,
    required this.previousLat,
    required this.previousLng,
    required this.routePoints,
  });

  final double totalDistanceMeters;
  final double previousLat;
  final double previousLng;
  final List<LatLng> routePoints;
}
