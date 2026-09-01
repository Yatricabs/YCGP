import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WHY THIS EXISTS:
/// This app calculates billed distance from GPS alone, often in areas
/// with no mobile network at all. When something unusual happens (a
/// mock-GPS fix is rejected, satellite signal is lost for a long
/// stretch, the location stream throws an error, or a ride had to be
/// resumed after the app was killed mid-ride), that event needs to be
/// captured automatically - not just silently handled - so support can
/// investigate a billing dispute or a recurring device problem later,
/// even if nobody was watching the phone screen at the time it happened.
///
/// Events are queued **locally first** (SharedPreferences, capped size)
/// precisely because network may not be available when the event
/// happens - a signal-loss event in a forest is exactly the moment
/// there's no connectivity to report it over. [trySync] is the hook to
/// actually deliver the queue once a backend endpoint exists and the
/// device has network again.
enum EventSeverity { info, warning, critical }

class AppEvent {
  AppEvent({
    required this.timestamp,
    required this.severity,
    required this.code,
    required this.message,
    this.context,
  });

  factory AppEvent.fromJson(Map<String, dynamic> json) => AppEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        severity: EventSeverity.values.firstWhere(
          (EventSeverity e) => e.name == json['severity'],
          orElse: () => EventSeverity.info,
        ),
        code: json['code'] as String,
        message: json['message'] as String,
        context: (json['context'] as Map<String, dynamic>?),
      );

  final DateTime timestamp;
  final EventSeverity severity;

  /// Short machine-readable identifier, e.g. 'MOCK_GPS_DETECTED',
  /// 'GPS_SIGNAL_GAP', 'RIDE_RESUMED_AFTER_RESTART'.
  final String code;
  final String message;
  final Map<String, dynamic>? context;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timestamp': timestamp.toIso8601String(),
        'severity': severity.name,
        'code': code,
        'message': message,
        if (context != null) 'context': context,
      };
}

class EventLogger {
  static const String _key = 'app_event_log';

  /// Caps local storage growth during a long no-network stretch - keeps
  /// only the most recent events if this limit is hit.
  static const int _maxStoredEvents = 200;

  Future<void> log(
    EventSeverity severity,
    String code,
    String message, {
    Map<String, dynamic>? context,
  }) async {
    // Always visible in the debug log immediately, regardless of whether
    // the persisted-queue write below succeeds.
    debugPrint('[EVENT:${severity.name.toUpperCase()}] $code - $message');

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> raw = prefs.getStringList(_key) ?? <String>[];
      final AppEvent event = AppEvent(
        timestamp: DateTime.now(),
        severity: severity,
        code: code,
        message: message,
        context: context,
      );
      raw.add(jsonEncode(event.toJson()));

      if (raw.length > _maxStoredEvents) {
        raw.removeRange(0, raw.length - _maxStoredEvents);
      }

      await prefs.setStringList(_key, raw);
    } catch (error) {
      debugPrint('EventLogger: failed to persist event locally: $error');
    }
  }

  Future<List<AppEvent>> getPendingEvents() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_key) ?? <String>[];
    return raw
        .map((String s) => AppEvent.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  /// Removes the oldest [count] events from the local queue - call this
  /// only after the backend has confirmed it received them.
  Future<void> clearSyncedEvents(int count) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> raw = prefs.getStringList(_key) ?? <String>[];
    if (count >= raw.length) {
      await prefs.remove(_key);
    } else {
      await prefs.setStringList(_key, raw.sublist(count));
    }
  }

  /// NOT WIRED UP YET - no backend endpoint was available when this was
  /// built. This is the intended shape of the sync call once one exists:
  ///
  ///   1. events = await getPendingEvents()
  ///   2. if (events.isEmpty) return;
  ///   3. POST events (as JSON) to something like /api/app-events
  ///   4. Only on a confirmed 2xx response:
  ///      await clearSyncedEvents(events.length)
  ///
  /// Never clear the local queue before a confirmed successful delivery -
  /// these events are themselves "something went wrong" signals, so
  /// losing them silently on a failed network call would defeat the
  /// purpose. Call this periodically (e.g. every time a GPS fix arrives
  /// successfully, since that already implies the device has some
  /// connectivity window worth trying) once the endpoint is ready.
  Future<void> trySync() async {
    // Intentionally left as a no-op hook - see doc comment above.
  }
}
