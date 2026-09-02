import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:floating/floating.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'event_logger.dart';
import 'gps_validator.dart';
import 'ride_persistence.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
        colorScheme: ColorScheme.fromSeed(seedColor: YatriColors.green),
      ),
      home: const RideScreen(),
    );
  }
}

class YatriColors {
  static const green = Color(0xFF58B436);
  static const background = Color(0xFFFFF9FF);
  static const dark = Color(0xFF343434);
}

class RideScreen extends StatefulWidget {
  const RideScreen({super.key});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> with WidgetsBindingObserver {
  // ------------------------------------------------------------
  // BUSINESS REQUIREMENT
  // Estimated distance is intentionally hard-coded.
  // It is NOT changed by GPS.
  // ------------------------------------------------------------
  static const double estimatedKm = 291.0;

  // Fallback only for drawing the map before browser/device GPS
  // becomes available. It does NOT count toward billing distance.
  static const LatLng fallbackLocation = LatLng(26.8467, 80.9462);

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
  final Floating _floating = Floating();
  final GpsFixValidator _validator = GpsFixValidator();
  final RidePersistence _persistence = RidePersistence();
  final EventLogger _eventLogger = EventLogger();

  LatLng _mapCenter = fallbackLocation;
  LatLng? _currentLocation;

  final List<LatLng> _routePoints = <LatLng>[];

  double _totalDistanceMeters = 0.0;
  double _heading = 0.0;
  bool _rideActive = false;
  bool _locationReady = false;
  bool _permissionDenied = false;
  String _status = 'Getting GPS location...';
  String _gpsSignalStatus = 'GPS: Searching...';

  // Unlike the standard Android battery-optimization exemption (a real
  // permission we can request and verify), the OEM-specific auto-start /
  // protected-app list has no API to enable it programmatically - only
  // the driver can flip it in their phone's own settings. A one-time
  // dialog is too easy to tap past and forget, so this stays true (and
  // a visible banner keeps showing) until we've actually verified it's
  // been turned on.
  bool _batteryOptimizationConcern = false;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _generateCarIcon();
    _initializeRide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _rideActive) {
      // The driver may have just come back from their phone's own
      // Settings app after following the battery/autostart guide - only
      // recheck the standard exemption we CAN verify (see
      // _checkBatteryOptimizationStatus), right away instead of waiting
      // for the next periodic check, so the banner clears as soon as
      // it's actually fixed.
      unawaited(_checkBatteryOptimizationStatus());
    }
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
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
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
    await _requestBatteryOptimizationExemption();

    // If the app was killed mid-ride last time (crash, OS kill, dead
    // battery), recover the distance/route collected so far instead of
    // silently restarting the bill from zero.
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

  Future<void> _requestBatteryOptimizationExemption() async {
    try {
      final ph.PermissionStatus status =
          await ph.Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        await ph.Permission.ignoreBatteryOptimizations.request();
      }
    } catch (error) {
      debugPrint('Battery optimization exemption request failed: $error');
    }

    // Standard Android battery-optimization exemption (above) does NOT
    // cover OEM-specific background restrictions - Xiaomi's MIUI,
    // Oppo/Realme's ColorOS, Vivo's FuntouchOS, and some Samsung builds
    // each ship their own separate "auto-start"/"protected apps" list
    // that sits entirely outside the standard Android API. There is no
    // programmatic way to enable these - only to guide the driver to the
    // right settings screen.
    //
    // IMPORTANT - history of this function, for whoever touches it next:
    // this used to (1) call the disable_battery_optimization plugin's
    // native OEM-specific dialogs, which crashed instantly on an
    // unrecognised device/manufacturer (uncatchable native
    // ActivityNotFoundException), then (2) call app_settings'
    // openAppSettings() in an auto-chained sequence of three dialogs
    // triggered off app-resume. On a real Xiaomi/MIUI test device, THAT
    // also crashed the app ("YATRI CABS keeps stopping") right after
    // tapping Continue on the second dialog in the chain.
    //
    // Two different plugins, two different crashes, both centered on
    // automatically launching a Settings intent and/or auto-chaining a
    // follow-up dialog off an app-resume signal. Rather than try a third
    // plugin, this now does the minimum-risk thing: show ONE plain
    // informational dialog with no automatic navigation at all, and let
    // the driver open Settings themselves from their home screen. It's
    // less convenient, but there is no intent-launch left for a plugin
    // (or a mis-timed resume callback) to crash on.
    try {
      await _showBatterySettingsGuide();
    } catch (error) {
      debugPrint('Battery settings guide failed: $error');
    }

    await _checkBatteryOptimizationStatus();
  }

  /// Checks whether the standard Android battery-optimization exemption
  /// is actually in place right now. There is no safe, universal way to
  /// verify the OEM-specific auto-start setting (see note above on why
  /// the plugin that used to check this was removed), so this focuses
  /// on the one signal we can check reliably without crash risk.
  Future<void> _checkBatteryOptimizationStatus() async {
    bool concern = false;

    try {
      final ph.PermissionStatus status =
          await ph.Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) concern = true;
    } catch (error) {
      debugPrint('Battery optimization status check failed: $error');
    }

    if (!mounted) return;
    setState(() {
      _batteryOptimizationConcern = concern;
    });
  }

  /// A single, purely informational dialog - it does NOT launch any
  /// Settings intent itself. The driver is told exactly what to go do in
  /// their own Settings app. No automatic navigation, no chained
  /// follow-up dialog, no dependency on an app-resume callback - so
  /// there is nothing left in this flow for a flaky OEM Settings
  /// integration to crash.
  Future<void> _showBatterySettingsGuide() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('One-time phone setup for reliable tracking'),
        content: const Text(
          'To keep tracking your ride reliably in the background, please '
          'open your phone\'s Settings app (outside YATRI CABS) and do the '
          'following for YATRI CABS:\n\n'
          '1. Battery > YATRI CABS > set to "Unrestricted" / "Don\'t '
          'optimize"\n'
          '2. If your phone has an "Autostart" or "Protected apps" list '
          '(Xiaomi, Vivo, Oppo, and others), turn it on for YATRI CABS\n'
          '3. If asked, also allow "Display over other apps"\n\n'
          'You only need to do this once.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  /// Educates the driver on the one thing no amount of code can fully
  /// guarantee against: some OEMs still kill a foreground service if the
  /// app is force-swiped away from the recent-apps list. This is shown
  /// once per fresh ride start.
  void _showKeepAppOpenWarning() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Keep the app running'),
        content: const Text(
          'Live GPS tracking will keep working while you use other apps '
          'or lock the screen. Just avoid force-closing YATRI CABS from '
          'the recent-apps list during the ride - that can stop tracking '
          'on some phones.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
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

    // Foreground ("while in use") permission alone is NOT enough to keep
    // GPS running once the screen locks or a phone call takes over the
    // screen - Android suspends it. A second prompt asking for "Allow all
    // the time" (background) is required; Android only shows this after
    // foreground access has already been granted.
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  void _startRideTracking(Position startingPosition, {RideProgress? resumeFrom}) {
    _positionSubscription?.cancel();

    if (resumeFrom != null) {
      // Recovering from a crash/OS-kill/dead-battery mid-ride: keep the
      // billed distance and route collected so far instead of zeroing
      // them out. There will be a small gap in the route for the time
      // the app was down - this is the "considerable but acceptable"
      // difference, not a full loss of billed distance.
      _totalDistanceMeters = resumeFrom.totalDistanceMeters;
      _previousLat = resumeFrom.previousLat;
      _previousLng = resumeFrom.previousLng;
      _previousAltitude = resumeFrom.previousAltitude;
      _previousFixTime = resumeFrom.previousFixTime;
      _routePoints
        ..clear()
        ..addAll(resumeFrom.routePoints);
      debugPrint(
        'Resumed ride after restart: '
        '${distanceCoveredKm.toStringAsFixed(3)}km already recorded',
      );
      unawaited(
        _eventLogger.log(
          EventSeverity.warning,
          'RIDE_RESUMED_AFTER_RESTART',
          'App restarted mid-ride (crash/OS kill/dead battery) - resumed '
              'from ${distanceCoveredKm.toStringAsFixed(3)}km instead of '
              'starting over.',
          context: <String, dynamic>{
            'recoveredDistanceMeters': _totalDistanceMeters,
          },
        ),
      );
    } else {
      _totalDistanceMeters = 0.0;
      _previousLat = startingPosition.latitude;
      _previousLng = startingPosition.longitude;
      _previousAltitude = startingPosition.altitude;
      _previousFixTime = startingPosition.timestamp;
      _routePoints
        ..clear()
        ..add(LatLng(startingPosition.latitude, startingPosition.longitude));
    }

    _rideActive = true;
    _locationReady = true;
    _isSlowPollMode = false;
    _lastPollModeSwitchAt = null;
    _highDistanceWarningLogged = false;

    // Keep the screen from turning off for the entire ride, and let the
    // app shrink into a small floating window (like Google Maps
    // navigation) instead of going fully into the background whenever the
    // driver switches to another app while a ride is active.
    WakelockPlus.enable();
    _floating.enable(const OnLeavePiP());

    if (mounted) setState(() {});

    if (resumeFrom == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showKeepAppOpenWarning(),
      );
    }

    _subscribeToPositionStream(slowPoll: false);

    // Self-healing safety net: if the position stream ever goes silent
    // for far longer than any single deep-signal-loss gap should
    // reasonably last, re-subscribe rather than staying stuck silently -
    // covers the rare case where the underlying stream itself dies
    // without throwing a catchable error.
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 30),
      _checkPositionStreamHealth,
    );
  }

  void _checkPositionStreamHealth(Timer timer) {
    if (!_rideActive) return;

    // Piggybacks on the existing 30-second watchdog tick rather than
    // running its own separate timer - cheap enough to check this often,
    // and it means the banner clears within 30s of the driver fixing it
    // even if they never background/foreground the app.
    unawaited(_checkBatteryOptimizationStatus());

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

  /// Runs GPS tracking as an Android foreground service (persistent
  /// notification while the ride is active) so it keeps updating even
  /// after the screen locks or an incoming call takes over the screen -
  /// a plain Dart Timer would get suspended by Android in that case.
  ///
  /// [slowPoll] trades fix frequency for battery life: while the vehicle
  /// is genuinely stationary (a long stop/break), there is nothing new to
  /// bill every 2 seconds, and a long remote ride can't afford to drain
  /// the battery polling that often the whole time. See
  /// [_maybeAdjustPollInterval] for when this switches back and forth.
  void _subscribeToPositionStream({required bool slowPoll}) {
    _positionSubscription?.cancel();

    final LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      intervalDuration: Duration(seconds: slowPoll ? 8 : 2),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'YATRI CABS - Ride in progress',
        notificationText: 'Tracking your live location for accurate billing',
        notificationIcon: AndroidResource(
          name: 'ic_notification',
          defType: 'drawable',
        ),
        enableWakeLock: true,
        setOngoing: true,
      ),
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
    final bool shouldSlowPoll =
        current.speed >= 0 && current.speed < GpsFixValidator.stationarySpeedThresholdMps;

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
            routePoints: _routePoints,
          ),
        );

        // Ride-level sanity net: catches slow, cumulative drift that no
        // single fix's per-fix checks would individually reject on its
        // own. Doesn't block billing - just flags it for a human to
        // review, since the estimate itself can legitimately be off.
        if (!_highDistanceWarningLogged &&
            distanceCoveredKm > estimatedKm * 2.5) {
          _highDistanceWarningLogged = true;
          unawaited(
            _eventLogger.log(
              EventSeverity.warning,
              'DISTANCE_EXCEEDS_ESTIMATE',
              'Distance covered (${distanceCoveredKm.toStringAsFixed(1)}km) '
                  'is more than 2.5x the estimated distance '
                  '(${estimatedKm.toStringAsFixed(0)}km) - needs review.',
              context: <String, dynamic>{
                'distanceCoveredKm': distanceCoveredKm,
                'estimatedKm': estimatedKm,
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

    _setGpsPosition(current, addBillingPoint: false);

    if (mounted) setState(() {});

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

  void _endRide() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _rideActive = false;
    WakelockPlus.disable();
    _floating.cancelOnLeavePiP();
    // Ride finished cleanly - nothing left to recover on next launch.
    unawaited(_persistence.clear());
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _watchdogTimer?.cancel();
    _mapController?.dispose();
    WakelockPlus.disable();
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
    return Scaffold(
      backgroundColor: YatriColors.background,
      body: SafeArea(
        child: Column(
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
      backgroundColor: YatriColors.background,
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
              color: YatriColors.green,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
              child: Text(
                distanceText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
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
                  color: YatriColors.green,
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
      color: YatriColors.green,
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
                color: YatriColors.green,
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
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
                      color: YatriColors.dark,
                    ),
                  ),
                ),
              ),
            ),
          if (_batteryOptimizationConcern && !_permissionDenied)
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    unawaited(_requestBatteryOptimizationExemption());
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFEF6C00)),
                    ),
                    child: const Row(
                      children: <Widget>[
                        Icon(
                          Icons.battery_alert,
                          color: Color(0xFFEF6C00),
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Battery settings not optimized - tap to fix '
                            'so tracking doesn\'t stop mid-ride',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFEF6C00),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDistanceCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 15),
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
      decoration: BoxDecoration(
        color: YatriColors.background,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: YatriColors.green, width: 2),
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
                  color: YatriColors.dark,
                ),
              ),
              Text(
                '${estimatedKm.toStringAsFixed(0)} KM',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: YatriColors.dark,
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
                    color: YatriColors.dark,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                distanceText,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w600,
                  color: YatriColors.dark,
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
        color: YatriColors.green,
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
                  color: YatriColors.green,
                  size: 38,
                ),
              ),
            ),
            const Positioned(
              right: 32,
              top: 20,
              child: Icon(
                Icons.settings_outlined,
                color: Colors.white,
                size: 38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
