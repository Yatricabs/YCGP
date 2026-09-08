import 'dart:convert';

import '../event_logger.dart';
import 'native_ride_bridge.dart';

/// Imports native crash/service diagnostics into the shared Dart event log.
class NativeDiagnostics {
  const NativeDiagnostics(this._bridge);

  final NativeRideBridge _bridge;

  Future<void> importInto(EventLogger logger) async {
    try {
      final dynamic raw = await _bridge.invoke<dynamic>('getDiagnosticsLog');
      if (raw is! String) return;

      final List<dynamic> entries = jsonDecode(raw) as List<dynamic>;
      for (final dynamic rawEntry in entries) {
        final Map<String, dynamic> entry = rawEntry as Map<String, dynamic>;
        final String type = entry['type'] as String? ?? 'NATIVE_EVENT';
        final int timestampMs = entry['timestamp'] as int? ?? 0;
        final Map<String, dynamic>? detail =
            entry['detail'] as Map<String, dynamic>?;

        await logger.log(
          EventSeverity.critical,
          type,
          _describe(type, detail),
          context: <String, dynamic>{
            if (timestampMs > 0)
              'nativeTimestamp':
                  DateTime.fromMillisecondsSinceEpoch(timestampMs)
                      .toIso8601String(),
            if (detail != null) ...detail,
          },
        );
      }

      if (entries.isNotEmpty) {
        await _bridge.invoke<dynamic>('clearDiagnosticsLog');
      }
    } catch (_) {
      // Diagnostics must never prevent the ride screen from starting.
    }
  }

  String _describe(String type, Map<String, dynamic>? detail) {
    switch (type) {
      case 'SERVICE_KILLED_UNEXPECTEDLY':
        return 'Ride tracking service was killed unexpectedly.';
      case 'APP_SWIPED_FROM_RECENTS':
        return 'App was swiped away while a ride was active.';
      case 'GPS_FIX_STALLED_AUTO_RECOVERED':
        return 'GPS delivery stalled and tracking restarted automatically.';
      case 'NATIVE_CRASH':
        return 'Native app crash: ${detail?['exceptionClass'] ?? 'unknown'}';
      default:
        return 'Native event: $type';
    }
  }
}
