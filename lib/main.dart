import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:floating/floating.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';

import 'event_logger.dart';
import 'gps_validator.dart';
import 'ride_persistence.dart';
import 'core/app_constants.dart';
import 'services/native_diagnostics.dart';
import 'services/native_ride_bridge.dart';
import 'services/saf_backup_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final EventLogger crashLogger = EventLogger();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(crashLogger.log(
      EventSeverity.critical,
      'DART_FRAMEWORK_ERROR',
      details.exceptionAsString(),
      context: <String, dynamic>{
        if (details.stack != null) 'stack': details.stack.toString(),
      },
    ));
  };
  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    unawaited(crashLogger.log(
      EventSeverity.critical,
      'DART_UNCAUGHT_ERROR',
      error.toString(),
      context: <String, dynamic>{'stack': stack.toString()},
    ));
    return false;
  };

  runApp(const YatriCabsApp());
}

class YatriCabsApp extends StatelessWidget {
  const YatriCabsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'YATRI CABS',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.green),
      ),
      home: const RideScreen(),
    );
  }
}

class RideScreen extends StatefulWidget {
  const RideScreen({super.key});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {
  // ------------------------------------------------------------
  // BUSINESS REQUIREMENT
  // Estimated distance is intentionally hard-coded.
  // It is NOT changed by GPS.
  // ------------------------------------------------------------
  // Fallback only for drawing the map before browser/device GPS
  // becomes available. It does NOT count toward billing distance.
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionSubscription;
  double? _previousLat;
  double? _previousLng;
  double? _previousAltitude;
  DateTime? _previousFixTime;
  bool _isSlowPollMode = false;
  DateTime? _lastPollModeSwitchAt;
  bool _highDistanceWarningLogged = false;
  Timer? _watchdogTimer;
  static const NativeRideBridge _nativeRideBridge = NativeRideBridge.instance;
  StreamSubscription<dynamic>? _nativeEventSubscription;
  bool _nativeServiceActive = false;
  DateTime? _lastNativeNotificationUpdate;
  Timer? _nativeHealthTimer;
  final GpsFixValidator _validator = GpsFixValidator();
  final RidePersistence _persistence = RidePersistence();
  final EventLogger _eventLogger = EventLogger();
  final NativeDiagnostics _nativeDiagnostics =
      NativeDiagnostics(NativeRideBridge.instance);

  LatLng _mapCenter = RideConfig.fallbackLocation;
  LatLng? _currentLocation;

  final List<LatLng> _routePoints = <LatLng>[];

  double _totalDistanceMeters = 0.0;
  double _heading = 0.0;
  bool _rideActive = false;
  bool _locationReady = false;
  bool _permissionDenied = false;
  String _status = 'Getting GPS location...';
  String _gpsSignalStatus = 'GPS: Searching...';
  DateTime? _rideStartTime;
  double _currentSpeedKmh = 0;
  BitmapDescriptor _carIcon = BitmapDescriptor.defaultMarker;

  Set<Marker> get _markers {
    if (_currentLocation == null) return <Marker>{};
    return <Marker>{
      Marker(
        markerId: const MarkerId('yatri_vehicle'),
        position: _currentLocation!,
        icon: _carIcon,
        rotation: _heading,
        flat: true,
        anchor: const Offset(0.5, 0.5),
        infoWindow: const InfoWindow(title: 'YATRI CABS'),
      ),
    };
  }

  Set<Polyline> get _polylines {
    if (_routePoints.length < 2) return <Polyline>{};
    return <Polyline>{
      Polyline(
        polylineId: const PolylineId('yatri_live_route'),
        points: List<LatLng>.unmodifiable(_routePoints),
        width: 6,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ),
    };
  }

  double get distanceCoveredKm => _totalDistanceMeters / 1000.0;

  String get distanceText => '${distanceCoveredKm.toStringAsFixed(1)}km';

  /// Trip-average speed: total distance over the entire ride duration
  /// (including stops), matching how a car's trip computer usually
  /// defines "average speed" - not just the moving-time average.
  double get averageSpeedKmh {
    final DateTime? startTime = _rideStartTime;
    if (startTime == null || _totalDistanceMeters <= 0) return 0;
    final double elapsedHours =
        DateTime.now().difference(startTime).inMilliseconds / 3600000.0;
    if (elapsedHours <= 0) return 0;
    return distanceCoveredKm / elapsedHours;
  }

  @override
  void initState() {
    super.initState();
    _generateCarIcon();
    _listenToNativeRideService();
    unawaited(_nativeDiagnostics.importInto(_eventLogger));
    _initializeRide();
  }

  Future<void> _ensureBackupFolderConfigured() async {
    if (await SafBackupService.hasBackupFolder() || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Choose a backup folder'),
        content: const Text(
          'Pick a folder once to keep a live backup of the active ride. '
          'You can skip this and configure it later from diagnostics.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Skip for now'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await SafBackupService.pickBackupFolder();
            },
            child: const Text('Choose folder'),
          ),
        ],
      ),
    );
  }

  /// Draws a small white top-view car marker entirely in code (no external
  /// image asset needed). The canvas is rendered at a higher pixel
  /// resolution for crisp edges, but `width`/`height` below pin the actual
  /// on-map size in logical pixels so it stays small and consistent across
  /// every phone's screen density (this is what was missing before and
  /// caused the oversized marker).
  Future<void> _generateCarIcon() async {
    const double canvasSize = 240; // high-res drawing surface
    const double onMapWidth = 30; // actual logical size shown on the map
    const double onMapHeight = 56;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, canvasSize, canvasSize),
    );
    final double cx = canvasSize / 2;
    final double cy = canvasSize / 2;

    // Soft drop shadow under the car.
    final Paint shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 8), width: 92, height: 150),
      shadowPaint,
    );

    // Top-view sedan silhouette: rounded nose at top, straight sides,
    // slightly rounded tail at bottom.
    final Path body = Path()
      ..moveTo(cx, cy - 96) // front-center (nose tip)
      ..quadraticBezierTo(cx + 44, cy - 96, cx + 44, cy - 60)
      ..lineTo(cx + 44, cy + 68)
      ..quadraticBezierTo(cx + 44, cy + 96, cx + 16, cy + 96)
      ..lineTo(cx - 16, cy + 96)
      ..quadraticBezierTo(cx - 44, cy + 96, cx - 44, cy + 68)
      ..lineTo(cx - 44, cy - 60)
      ..quadraticBezierTo(cx - 44, cy - 96, cx, cy - 96)
      ..close();

    canvas.drawPath(body, Paint()..color = Colors.white);
    canvas.drawPath(
      body,
      Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );

    // Windshield (front glass).
    final RRect windshield = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy - 48), width: 62, height: 34),
      const Radius.circular(8),
    );
    canvas.drawRRect(windshield, Paint()..color = const Color(0xFFB9C2C9));

    // Rear windshield.
    final RRect rearWindow = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 74), width: 54, height: 26),
      const Radius.circular(7),
    );
    canvas.drawRRect(rearWindow, Paint()..color = const Color(0xFFB9C2C9));

    // Cabin/roof strip in the middle.
    final RRect roof = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + 6), width: 58, height: 74),
      const Radius.circular(10),
    );
    canvas.drawRRect(roof, Paint()..color = const Color(0xFFF1F3F4));

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(
      canvasSize.toInt(),
      canvasSize.toInt(),
    );
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || !mounted) return;

    setState(() {
      _carIcon = BitmapDescriptor.bytes(
        bytes.buffer.asUint8List(),
        width: onMapWidth,
        height: onMapHeight,
      );
    });
  }

  Future<void> _initializeRide() async {
    await _ensureNotificationPermission();
    final bool permissionOk = await _ensureLocationPermission();

    if (!permissionOk) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _status = 'Location permission required';
      });
      unawaited(
        _eventLogger.log(
          EventSeverity.warning,
          'LOCATION_PERMISSION_DENIED',
          'Ride could not start - location permission was not granted.',
        ),
      );
      return;
    }

    // Some OEMs (Xiaomi/Vivo/Oppo/Samsung especially) aggressively kill
    // background location tracking to save battery - exactly when it
    // matters most, on long low-signal rural stretches where the radio
    // works harder. Ask once to be exempted.
    // If the app was killed mid-ride last time (crash, OS kill, dead
    // battery), recover the distance/route collected so far instead of
    // silently restarting the bill from zero.
    await _ensureBackupFolderConfigured();
    final RideProgress? recovered = await _persistence.loadInProgressRide();

    try {
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      _setGpsPosition(position, addBillingPoint: false);

      // The reference screen is already in an active ride state,
      // therefore GPS tracking starts automatically.
      _startRideTracking(position, resumeFrom: recovered);
    } catch (error) {
      debugPrint('Initial GPS error: $error');
      unawaited(
        _eventLogger.log(
          EventSeverity.critical,
          'INITIAL_GPS_UNAVAILABLE',
          'Could not get an initial GPS fix to start the ride: $error',
        ),
      );
      if (!mounted) return;
      setState(() {
        _status = 'GPS unavailable';
      });
    }
  }

  Future<void> _ensureNotificationPermission() async {
    try {
      if (await ph.Permission.notification.isDenied) {
        await ph.Permission.notification.request();
      }
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted) return false;
      await Geolocator.openLocationSettings();
      return await Geolocator.isLocationServiceEnabled();
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _permissionDenied = true;
          _status = 'Enable location permission in Settings';
        });
      }
      return false;
    }

    // The native location foreground service is started from the visible
    // ride screen, so we intentionally request only the minimum location
    // scope needed for the active ride. ACCESS_BACKGROUND_LOCATION is not
    // forced here.
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<void> _startRideTracking(Position startingPosition,
      {RideProgress? resumeFrom}) async {
    _positionSubscription?.cancel();

    if (resumeFrom != null) {
      _totalDistanceMeters = resumeFrom.totalDistanceMeters;
      _previousLat = resumeFrom.previousLat;
      _previousLng = resumeFrom.previousLng;
      _previousAltitude = resumeFrom.previousAltitude;
      _previousFixTime = resumeFrom.previousFixTime;
      _rideStartTime = resumeFrom.rideStartTime;
      _routePoints
        ..clear()
        ..addAll(resumeFrom.routePoints);
      unawaited(_eventLogger.log(
        EventSeverity.warning,
        'RIDE_RESUMED_AFTER_RESTART',
        'App restarted mid-ride and resumed from persisted progress.',
        context: <String, dynamic>{
          'recoveredDistanceMeters': _totalDistanceMeters
        },
      ));
    } else {
      _totalDistanceMeters = 0.0;
      _previousLat = startingPosition.latitude;
      _previousLng = startingPosition.longitude;
      _previousAltitude = startingPosition.altitude;
      _previousFixTime = startingPosition.timestamp;
      _rideStartTime = startingPosition.timestamp;
      _currentSpeedKmh = 0;
      _routePoints
        ..clear()
        ..add(LatLng(startingPosition.latitude, startingPosition.longitude));
      // Mark the ride recoverable immediately, before the first accepted
      // movement segment arrives. A process death in these first seconds
      // must not turn an active ride into an unrecoverable one.
      unawaited(_persistence.saveProgress(
        totalDistanceMeters: 0.0,
        previousLat: startingPosition.latitude,
        previousLng: startingPosition.longitude,
        previousAltitude: startingPosition.altitude,
        previousFixTime: startingPosition.timestamp,
        rideStartTime: startingPosition.timestamp,
        routePoints: _routePoints,
      ));
    }

    _rideActive = true;
    _locationReady = true;
    _isSlowPollMode = false;
    _lastPollModeSwitchAt = null;
    _highDistanceWarningLogged = false;

    try {
      WakelockPlus.enable();
    } catch (error) {
      debugPrint('Wakelock enable failed: $error');
    }

    if (mounted) setState(() {});

    final bool nativeStarted = await _startNativeForegroundService();
    if (!nativeStarted) {
      _subscribeToPositionStream(slowPoll: false);
      unawaited(_eventLogger.log(
        EventSeverity.critical,
        'NATIVE_FGS_START_FAILED_USING_FALLBACK',
        'Native foreground location service did not start; reverted to the existing Dart GPS stream.',
      ));
    }

    _watchdogTimer?.cancel();
    _watchdogTimer =
        Timer.periodic(const Duration(seconds: 30), _checkPositionStreamHealth);
    _nativeHealthTimer?.cancel();
    _nativeHealthTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _checkNativeServiceHealth());

    if (resumeFrom == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_rideActive) return;
        _showBackgroundProtectionDialog();
      });
    }
  }

  Future<void> _listenToNativeRideService() async {
    _nativeEventSubscription?.cancel();
    _nativeEventSubscription = _nativeRideBridge.events.listen(
      (dynamic event) {
        if (event is! String) return;
        try {
          final Map<String, dynamic> payload =
              jsonDecode(event) as Map<String, dynamic>;
          final String type = payload['type']?.toString() ?? '';
          if (type == 'location') {
            _handleNativeLocation(payload);
          } else if (type == 'service') {
            final String status = payload['status']?.toString() ?? 'UNKNOWN';
            _nativeServiceActive = payload['active'] == true;
            if (status == 'TASK_REMOVED') {
              unawaited(_eventLogger.log(
                EventSeverity.warning,
                'APP_TASK_REMOVED_SERVICE_CONTINUES',
                'Android removed the app task while the active ride service continued.',
              ));
            }
            if (mounted) setState(() {});
          }
        } catch (error) {
          debugPrint('Native ride event parse error: $error');
        }
      },
      onError: (Object error) =>
          debugPrint('Native ride event channel error: $error'),
    );
  }

  Future<bool> _startNativeForegroundService() async {
    try {
      await _nativeRideBridge.invoke<void>('startRideService');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final dynamic health =
          await _nativeRideBridge.invoke<dynamic>('getServiceHealth');
      if (health is String) {
        final Map<String, dynamic> data =
            jsonDecode(health) as Map<String, dynamic>;
        _nativeServiceActive =
            data['active'] == true && data['serviceAlive'] == true;
      } else {
        _nativeServiceActive = true;
      }
      if (_nativeServiceActive) {
        await _replayQueuedNativeLocations();
        _updateNativeNotification(force: true);
      }
      return _nativeServiceActive;
    } catch (error) {
      debugPrint('Native foreground service start failed: $error');
      _nativeServiceActive = false;
      return false;
    }
  }

  Future<void> _replayQueuedNativeLocations() async {
    try {
      final dynamic queued =
          await _nativeRideBridge.invoke<dynamic>('drainQueuedLocations');
      if (queued is! List) return;
      for (final dynamic raw in queued) {
        if (raw is String) {
          try {
            _handleNativeLocation(jsonDecode(raw) as Map<String, dynamic>);
          } catch (error) {
            debugPrint('Queued native fix parse failed: $error');
          }
        }
      }
    } catch (error) {
      debugPrint('Queued native location replay failed: $error');
    }
  }

  void _handleNativeLocation(Map<String, dynamic> payload) {
    if (!_rideActive) return;
    final int timestampMs = (payload['timestamp'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final Position position = Position(
      latitude: (payload['latitude'] as num).toDouble(),
      longitude: (payload['longitude'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      accuracy: (payload['accuracy'] as num?)?.toDouble() ?? 0.0,
      altitude: (payload['altitude'] as num?)?.toDouble() ?? 0.0,
      altitudeAccuracy: 0.0,
      heading: (payload['heading'] as num?)?.toDouble() ?? 0.0,
      headingAccuracy: 0.0,
      speed: (payload['speed'] as num?)?.toDouble() ?? 0.0,
      speedAccuracy: 0.0,
      floor: null,
      isMocked: payload['isMocked'] == true,
    );
    _handleNewPosition(position);
  }

  Future<void> _stopNativeForegroundService() async {
    try {
      await _nativeRideBridge.invoke<void>('stopRideService');
    } catch (error) {
      debugPrint('Native foreground service stop failed: $error');
    }
    _nativeServiceActive = false;
  }

  void _updateNativeNotification({bool force = false}) {
    if (!_nativeServiceActive) return;
    final DateTime now = DateTime.now();
    if (!force &&
        _lastNativeNotificationUpdate != null &&
        now.difference(_lastNativeNotificationUpdate!) <
            const Duration(seconds: 5)) {
      return;
    }
    _lastNativeNotificationUpdate = now;
    unawaited(
        _nativeRideBridge.invoke<void>('updateNotification', <String, dynamic>{
      'distance': distanceText,
      'speed': '${_currentSpeedKmh.toStringAsFixed(0)} km/h',
      'status': _gpsSignalStatus,
    }).catchError((Object error) {
      debugPrint('Native notification update failed: $error');
    }));
  }

  Future<void> _checkNativeServiceHealth() async {
    if (!_rideActive) return;
    try {
      final dynamic raw =
          await _nativeRideBridge.invoke<dynamic>('getServiceHealth');
      if (raw is! String) return;
      final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
      final bool active = data['active'] == true;
      final bool alive = data['serviceAlive'] == true;
      final int lastFixAt = (data['lastFixAt'] as num?)?.toInt() ?? 0;
      final int ageMs =
          lastFixAt > 0 ? DateTime.now().millisecondsSinceEpoch - lastFixAt : 0;
      _nativeServiceActive = active && alive;
      if (!_nativeServiceActive) {
        unawaited(_eventLogger.log(
          EventSeverity.critical,
          'NATIVE_FGS_NOT_RUNNING',
          'Active ride detected that the Android foreground service is no longer running; attempting recovery.',
        ));
        final bool restarted = await _startNativeForegroundService();
        if (!restarted && mounted)
          setState(() => _status = 'Background service unavailable');
      } else if (ageMs > 90 * 1000 && mounted) {
        setState(() => _status = 'GPS signal gap - service still active');
      }
    } catch (error) {
      debugPrint('Native service health check failed: $error');
    }
  }

  void _checkPositionStreamHealth(Timer timer) {
    if (!_rideActive) return;
    if (_nativeServiceActive) {
      unawaited(_checkNativeServiceHealth());
      return;
    }

    final DateTime? lastFixTime = _previousFixTime;
    if (lastFixTime == null) return;

    final Duration silence = DateTime.now().difference(lastFixTime);
    if (silence > const Duration(seconds: 90)) {
      debugPrint(
        'GPS watchdog: no fix for ${silence.inSeconds}s - restarting the '
        'location stream as a precaution.',
      );
      unawaited(
        _eventLogger.log(
          EventSeverity.warning,
          'GPS_STREAM_WATCHDOG_RESTART',
          'No GPS fix for ${silence.inSeconds}s while a ride was active - '
              'restarted the location stream as a precaution. May simply '
              'be a genuine deep signal-loss stretch, or the underlying '
              'stream silently stalling.',
          context: <String, dynamic>{'silenceSeconds': silence.inSeconds},
        ),
      );
      _subscribeToPositionStream(slowPoll: _isSlowPollMode);
    }
  }

  /// Legacy Dart GPS fallback used only if the native foreground service cannot start.
  ///
  /// The primary active-ride path is the custom native Android location
  /// foreground service. Keeping this fallback protects the existing v35
  /// tracking behavior on a device/build where native service startup fails.
  /// It never creates a second foreground service through Geolocator.
  ///
  void _subscribeToPositionStream({required bool slowPoll}) {
    _positionSubscription?.cancel();

    final LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      intervalDuration: Duration(seconds: slowPoll ? 8 : 2),
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _handleNewPosition,
      onError: (Object error) {
        debugPrint('Position stream error: $error');
        unawaited(
          _eventLogger.log(
            EventSeverity.critical,
            'POSITION_STREAM_ERROR',
            'The GPS position stream threw an error: $error',
          ),
        );
      },
    );
  }

  /// Switches between the normal 2-second poll and a battery-saving
  /// 8-second poll based on the vehicle's reported speed. A short cooldown
  /// avoids restarting the stream (and its foreground-service handoff) on
  /// every single fix if speed is hovering right at the threshold.
  void _maybeAdjustPollInterval(Position current) {
    final bool shouldSlowPoll = current.speed >= 0 &&
        current.speed < GpsFixValidator.stationarySpeedThresholdMps;

    if (_nativeServiceActive) return;
    if (shouldSlowPoll == _isSlowPollMode) return;

    final DateTime? lastSwitch = _lastPollModeSwitchAt;
    if (lastSwitch != null &&
        DateTime.now().difference(lastSwitch) < const Duration(seconds: 15)) {
      return;
    }

    _isSlowPollMode = shouldSlowPoll;
    _lastPollModeSwitchAt = DateTime.now();
    debugPrint(
      shouldSlowPoll
          ? 'Vehicle stationary - switching to battery-saving 8s GPS polling'
          : 'Vehicle moving again - switching back to 2s GPS polling',
    );
    _subscribeToPositionStream(slowPoll: shouldSlowPoll);
  }

  void _handleNewPosition(Position current) {
    if (!_rideActive) return;

    final double? prevLat = _previousLat;
    final double? prevLng = _previousLng;
    final double? prevAltitude = _previousAltitude;
    final DateTime? prevTime = _previousFixTime;

    if (prevLat != null && prevLng != null && prevTime != null) {
      final GpsFixResult result = _validator.evaluate(
        current: current,
        previousLat: prevLat,
        previousLng: prevLng,
        previousAltitude: prevAltitude ?? current.altitude,
        previousFixTime: prevTime,
      );

      // Anomaly reporting: capture the events that actually matter for a
      // billing dispute or a device-health investigation later - not
      // every routine low-accuracy rejection, which is normal and common
      // in hills/forest and would just add noise.
      if (current.isMocked) {
        unawaited(
          _eventLogger.log(
            EventSeverity.critical,
            'MOCK_GPS_DETECTED',
            'A GPS fix flagged as mock/fake location was rejected.',
            context: <String, dynamic>{
              'lat': current.latitude,
              'lng': current.longitude,
            },
          ),
        );
      }

      final double elapsedSeconds =
          current.timestamp.difference(prevTime).inMilliseconds / 1000.0;
      if (elapsedSeconds > 60) {
        unawaited(
          _eventLogger.log(
            EventSeverity.warning,
            'GPS_SIGNAL_GAP',
            'No GPS fix received for ${elapsedSeconds.toStringAsFixed(0)}s '
                '(likely a tunnel/valley/dense-canopy signal loss).',
            context: <String, dynamic>{'gapSeconds': elapsedSeconds},
          ),
        );
      }

      if (result.countTowardBilling) {
        _totalDistanceMeters += result.segmentMeters;
        _routePoints.add(LatLng(current.latitude, current.longitude));

        // Save immediately after every accepted fix - if the app gets
        // killed mid-ride, at most the last couple of seconds of travel
        // are ever at risk, never the whole ride's billed distance.
        unawaited(
          _persistence.saveProgress(
            totalDistanceMeters: _totalDistanceMeters,
            previousLat: current.latitude,
            previousLng: current.longitude,
            previousAltitude: current.altitude,
            previousFixTime: current.timestamp,
            rideStartTime: _rideStartTime ?? current.timestamp,
            routePoints: _routePoints,
          ),
        );

        // Ride-level sanity net: catches slow, cumulative drift that no
        // single fix's per-fix checks would individually reject on its
        // own. Doesn't block billing - just flags it for a human to
        // review, since the estimate itself can legitimately be off.
        if (!_highDistanceWarningLogged &&
            distanceCoveredKm > RideConfig.estimatedKm * 2.5) {
          _highDistanceWarningLogged = true;
          unawaited(
            _eventLogger.log(
              EventSeverity.warning,
              'DISTANCE_EXCEEDS_ESTIMATE',
              'Distance covered (${distanceCoveredKm.toStringAsFixed(1)}km) '
                  'is more than 2.5x the estimated distance '
                  '(${RideConfig.estimatedKm.toStringAsFixed(0)}km) - needs review.',
              context: <String, dynamic>{
                'distanceCoveredKm': distanceCoveredKm,
                'estimatedKm': RideConfig.estimatedKm,
              },
            ),
          );
        }
      }

      debugPrint(
        'GPS fix: accuracy=${current.accuracy.toStringAsFixed(1)}m | '
        'accepted=${result.countTowardBilling} | '
        '${result.reason ?? "counted ${result.segmentMeters.toStringAsFixed(1)}m"} | '
        'total=${distanceCoveredKm.toStringAsFixed(3)}km',
      );
    }

    _previousLat = current.latitude;
    _previousLng = current.longitude;
    _previousAltitude = current.altitude;
    _previousFixTime = current.timestamp;
    _gpsSignalStatus = GpsFixValidator.describeSignal(current.accuracy);
    if (current.speed >= 0) {
      _currentSpeedKmh = current.speed * 3.6;
    }

    _setGpsPosition(current, addBillingPoint: false);

    if (mounted) setState(() {});
    _updateNativeNotification();

    _moveCamera(LatLng(current.latitude, current.longitude));

    _maybeAdjustPollInterval(current);
  }

  void _setGpsPosition(Position position, {required bool addBillingPoint}) {
    final LatLng location = LatLng(position.latitude, position.longitude);
    _currentLocation = location;
    _mapCenter = location;
    if (position.heading >= 0) {
      _heading = position.heading;
    }

    if (addBillingPoint) {
      _routePoints.add(location);
    }
  }

  Future<void> _moveCamera(LatLng location) async {
    final GoogleMapController? controller = _mapController;
    if (controller == null) return;

    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: location, zoom: 16.0),
        ),
      );
    } catch (_) {
      // Ignore camera errors during map initialization.
    }
  }

  Future<void> _showBackgroundProtectionDialog() async {
    if (!mounted) return;
    Map<String, dynamic> profile = <String, dynamic>{};
    try {
      final dynamic raw =
          await _nativeRideBridge.invoke<dynamic>('getDeviceProfile');
      if (raw is Map) {
        profile = raw.map(
            (dynamic key, dynamic value) => MapEntry(key.toString(), value));
      }
    } catch (error) {
      debugPrint('Device profile lookup failed: $error');
    }

    final String manufacturer =
        (profile['manufacturer'] ?? '').toString().toLowerCase();
    final String brand = (profile['brand'] ?? '').toString().toLowerCase();
    final String model = (profile['model'] ?? 'this phone').toString();
    final String family = [manufacturer, brand].join(' ');

    String guidance;
    if (family.contains('xiaomi') ||
        family.contains('redmi') ||
        family.contains('poco')) {
      guidance =
          'Xiaomi/Redmi/POCO: keep YATRI unrestricted in Battery settings, allow Background Autostart where available, and avoid locking/force-stopping YATRI during an active ride.';
    } else if (family.contains('oppo')) {
      guidance =
          'OPPO/ColorOS: allow YATRI foreground/background activity and auto-launch where those controls are available. Do not force-stop the app during an active ride.';
    } else if (family.contains('realme')) {
      guidance =
          'realme UI: allow foreground activity, background activity and auto-launch for YATRI where available. Do not force-stop the app during an active ride.';
    } else if (family.contains('samsung')) {
      guidance =
          'Samsung One UI: do not place YATRI in Sleeping or Deep Sleeping apps. Use the Never auto sleeping list for long active rides when needed.';
    } else if (family.contains('oneplus')) {
      guidance =
          'OnePlus/OxygenOS: avoid restrictive battery optimization for YATRI during active rides and keep background activity allowed.';
    } else if (family.contains('vivo')) {
      guidance =
          'vivo/Funtouch OS: allow normal background activity and any available auto-start/background-power permission for YATRI during active rides.';
    } else if (family.contains('lava')) {
      guidance =
          'Lava: behavior varies by model and Android build. Keep YATRI allowed to run in the background and do not force-stop it. This device should be included in field validation.';
    } else {
      guidance =
          'Android will keep the active location service visible with a persistent notification. Keep YATRI allowed to run in the background and avoid force-stopping it during an active ride.';
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Background protection'),
        content: Text(
            '$model\n\n$guidance\n\nThe ride service is genuine Android foreground location work. No hidden keep-alive or fake activity is used.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmExitApp() async {
    if (!mounted) return;
    final bool? close = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Close YATRI CABS?'),
        content: Text(
          _rideActive
              ? 'The screen will close, but the active ride will continue through the Android foreground service and notification.'
              : 'Are you sure you want to close YATRI CABS?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (close == true) {
      await _nativeRideBridge.invoke<void>('closeTask');
    }
  }

  void _enterPictureInPicture() {
    unawaited(
        _nativeRideBridge.invoke<void>('enterPip').catchError((Object error) {
      debugPrint('PiP request failed: $error');
    }));
  }

  void _endRide() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _nativeHealthTimer?.cancel();
    _nativeHealthTimer = null;
    _rideActive = false;
    unawaited(_stopNativeForegroundService());
    try {
      WakelockPlus.disable();
    } catch (error) {
      debugPrint('Wakelock disable failed: $error');
    }
    unawaited(_persistence.clear());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _watchdogTimer?.cancel();
    _nativeHealthTimer?.cancel();
    _nativeEventSubscription?.cancel();
    _mapController?.dispose();
    try {
      WakelockPlus.disable();
    } catch (error) {
      debugPrint('Wakelock disable failed: $error');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PiPSwitcher(
      childWhenEnabled: _buildPipView(),
      childWhenDisabled: _buildFullScreen(),
    );
  }

  Widget _buildFullScreen() {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (didPop) return;
        if (_rideActive) {
          _enterPictureInPicture();
        } else {
          _confirmExitApp();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  _buildProgress(),
                  _buildEndRideButton(),
                  const SizedBox(height: 18),
                  Expanded(child: _buildMap()),
                  const SizedBox(height: 16),
                  _buildDistanceCard(),
                  const SizedBox(height: 18),
                  _buildBottomBar(),
                ],
              ),
              Positioned(
                top: 4,
                right: 8,
                child: Material(
                  color: Colors.transparent,
                  child: PopupMenuButton<String>(
                    tooltip: 'Ride options',
                    onSelected: (String value) {
                      switch (value) {
                        case 'pip':
                          _enterPictureInPicture();
                          break;
                        case 'protection':
                          unawaited(_showBackgroundProtectionDialog());
                          break;
                        case 'diagnostics':
                          unawaited(_showDiagnosticsLogViewer());
                          break;
                        case 'close':
                          unawaited(_confirmExitApp());
                          break;
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                          value: 'pip', child: Text('Minimize to PiP')),
                      PopupMenuItem<String>(
                          value: 'diagnostics', child: Text('Diagnostics log')),
                      PopupMenuItem<String>(
                          value: 'protection',
                          child: Text('Background protection')),
                      PopupMenuItem<String>(
                          value: 'close', child: Text('Close YATRI CABS')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Small view shown when the app has shrunk into the floating
  /// Picture-in-Picture window (e.g. driver switched to another app mid
  /// ride) - the OS does not deliver touch input to this view, so it is
  /// kept to just the map and the live distance, matching how Google Maps
  /// shows a minimal floating window during turn-by-turn navigation.
  Widget _buildPipView() {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _mapCenter,
              zoom: 16.0,
            ),
            myLocationEnabled: true,
            zoomControlsEnabled: false,
            zoomGesturesEnabled: false,
            scrollGesturesEnabled: false,
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            compassEnabled: false,
            mapToolbarEnabled: false,
            markers: _markers,
            polylines: _polylines,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: AppColors.green,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
              child: Text(
                '$distanceText  •  ${_currentSpeedKmh.toStringAsFixed(0)} km/h',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDiagnosticsLogViewer() async {
    if (!mounted) return;
    await _nativeDiagnostics.importInto(_eventLogger);
    final List<AppEvent> events = await _eventLogger.getPendingEvents();
    final List<AppEvent> recent = events.reversed.toList();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Diagnostics log'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: recent.isEmpty
              ? const Center(child: Text('No events recorded yet.'))
              : ListView.separated(
                  itemCount: recent.length,
                  separatorBuilder: (_, __) => const Divider(height: 16),
                  itemBuilder: (BuildContext context, int index) {
                    final AppEvent event = recent[index];
                    final Color color = switch (event.severity) {
                      EventSeverity.critical => Colors.red,
                      EventSeverity.warning => Colors.orange,
                      EventSeverity.info => AppColors.dark,
                    };
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${event.timestamp.toLocal()}  •  ${event.code}',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: color,
                              fontSize: 12),
                        ),
                        const SizedBox(height: 2),
                        Text(event.message,
                            style: const TextStyle(fontSize: 13)),
                      ],
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              final bool granted = await SafBackupService.pickBackupFolder();
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                      content: Text(granted
                          ? 'Backup folder set'
                          : 'No folder selected')),
                );
              }
            },
            child: const Text('Backup folder'),
          ),
          TextButton(
            onPressed: () {
              final String text = recent
                  .map((AppEvent event) =>
                      '${event.timestamp} [${event.severity.name}] ${event.code}: ${event.message}')
                  .join('\n\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy all'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 7, 22, 5),
      child: Row(
        children: <Widget>[
          _step('1', 'Initiate Pickup'),
          _connector(),
          _step('2', 'Reached\nPickup'),
          _connector(),
          _step('3', 'Boarded'),
          _connector(),
          _step('4', 'End Ride'),
        ],
      ),
    );
  }

  Widget _step(String number, String label) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double diameter = constraints.maxWidth < 58 ? 46 : 56;
              return Container(
                width: diameter,
                height: diameter,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.green,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.16),
                      blurRadius: 5,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Text(
                  number,
                  style: TextStyle(
                    fontSize: diameter < 50 ? 20 : 24,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.05,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _connector() {
    return Container(
      width: 24,
      height: 3,
      margin: const EdgeInsets.only(bottom: 27),
      color: AppColors.green,
    );
  }

  Widget _buildEndRideButton() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = (constraints.maxWidth * 0.60).clamp(250.0, 380.0);
        return Center(
          child: GestureDetector(
            onTap: _rideActive ? _endRide : null,
            child: Container(
              width: width,
              height: 85,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.green,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Text(
                'End Ride',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMap() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: <Widget>[
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _mapCenter,
              zoom: 15.5,
            ),
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
              if (_currentLocation != null) {
                _moveCamera(_currentLocation!);
              }
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,
            mapToolbarEnabled: false,
            compassEnabled: true,
            markers: _markers,
            polylines: _polylines,
          ),
          if (_permissionDenied)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          if (!_locationReady && !_permissionDenied)
            const Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      child: Text(
                        'Getting GPS location...',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_locationReady && !_permissionDenied)
            Positioned(
              top: 10,
              right: 10,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    _gpsSignalStatus,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.dark,
                    ),
                  ),
                ),
              ),
            ),
          if (_locationReady && !_permissionDenied) _buildSpeedCard(),
        ],
      ),
    );
  }

  /// Small speedometer-style panel on the map: current speed prominent
  /// (large, live-updating every fix) with trip-average speed shown
  /// underneath in smaller text.
  Widget _buildSpeedCard() {
    return Positioned(
      left: 10,
      top: 10,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.green,
            borderRadius: BorderRadius.circular(10),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Text(
                    _currentSpeedKmh.toStringAsFixed(0),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'km/h',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              Text(
                'Avg ${averageSpeedKmh.toStringAsFixed(0)} km/h',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDistanceCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 15),
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.green, width: 2),
      ),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              const Text(
                'Estimated Km',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: AppColors.dark,
                ),
              ),
              Text(
                '${RideConfig.estimatedKm.toStringAsFixed(0)} KM',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: AppColors.dark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              const Flexible(
                child: Text(
                  'Distance Covered',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    color: AppColors.dark,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                distanceText,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w600,
                  color: AppColors.dark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return SizedBox(
      height: 82,
      child: Container(
        color: AppColors.green,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: <Widget>[
            Positioned(
              left: 32,
              top: 18,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.sort, color: Colors.white, size: 29),
              ),
            ),
            Positioned(
              top: -29,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.20),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.phone,
                  color: AppColors.green,
                  size: 38,
                ),
              ),
            ),
            Positioned(
              right: 32,
              top: 20,
              child: GestureDetector(
                onTap: _showDiagnosticsLogViewer,
                child: const Icon(
                  Icons.settings_outlined,
                  color: Colors.white,
                  size: 38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
