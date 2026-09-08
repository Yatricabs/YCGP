import 'package:flutter/services.dart';

/// Owns the Flutter-to-Android bridge for active ride background behavior.
///
/// Keeping channel names and method calls here prevents the ride screen from
/// depending directly on platform-channel implementation details.
class NativeRideBridge {
  const NativeRideBridge._();

  static const NativeRideBridge instance = NativeRideBridge._();

  static const MethodChannel _methodChannel =
      MethodChannel('yatri_cabs/ride_service');
  static const EventChannel _eventChannel =
      EventChannel('yatri_cabs/ride_events');

  Stream<dynamic> get events => _eventChannel.receiveBroadcastStream();

  Future<T?> invoke<T>(String method, [dynamic arguments]) {
    return _methodChannel.invokeMethod<T>(method, arguments);
  }
}
