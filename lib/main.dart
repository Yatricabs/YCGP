import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

class _RideScreenState extends State<RideScreen> {
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
  Timer? _gpsTimer;
  Position? _previousPosition;

  LatLng _mapCenter = fallbackLocation;
  LatLng? _currentLocation;

  final List<LatLng> _routePoints = <LatLng>[];

  double _totalDistanceMeters = 0.0;
  double _heading = 0.0;
  bool _rideActive = false;
  bool _locationReady = false;
  bool _permissionDenied = false;
  String _status = 'Getting GPS location...';
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
    _generateCarIcon();
    _initializeRide();
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
      return;
    }

    try {
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      _setGpsPosition(position, addBillingPoint: false);

      // The reference screen is already in an active ride state,
      // therefore GPS tracking starts automatically.
      _startRideTracking(position);
    } catch (error) {
      debugPrint('Initial GPS error: $error');
      if (!mounted) return;
      setState(() {
        _status = 'GPS unavailable';
      });
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

    return permission != LocationPermission.denied;
  }

  void _startRideTracking(Position startingPosition) {
    _gpsTimer?.cancel();

    _previousPosition = startingPosition;
    _totalDistanceMeters = 0.0;
    _routePoints
      ..clear()
      ..add(LatLng(startingPosition.latitude, startingPosition.longitude));

    _rideActive = true;
    _locationReady = true;

    if (mounted) setState(() {});

    // Exactly one GPS read every 2 seconds while the ride is active.
    _gpsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _updateLiveGps();
    });
  }

  Future<void> _updateLiveGps() async {
    if (!_rideActive) return;

    try {
      final Position current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final Position? previous = _previousPosition;

      if (previous != null) {
        final double segmentMeters = Geolocator.distanceBetween(
          previous.latitude,
          previous.longitude,
          current.latitude,
          current.longitude,
        );

        // Billing protection:
        // 1) Ignore very poor GPS fixes (accuracy worse than 100 m).
        // 2) Ignore essentially-zero movement (< 1 m) - this is GPS jitter
        //    while the phone is sitting still, NOT a real-world minimum
        //    speed. (The old 3 m floor silently discarded normal walking
        //    speed - ~2-2.5 m every 2 sec - which is why the total stayed
        //    stuck at 0.0 km even while actually moving.)
        // 3) Ignore an impossible jump (> 400 m in a 2-sec sample, i.e.
        //    faster than ~720 km/h) - this is a GPS glitch/teleport, not
        //    real movement.
        final bool accuracyOk = current.accuracy <= 100;
        final bool isRealMovement = segmentMeters >= 1 && segmentMeters <= 400;

        if (accuracyOk && isRealMovement) {
          _totalDistanceMeters += segmentMeters;
          _routePoints.add(
            LatLng(current.latitude, current.longitude),
          );
        }

        debugPrint(
          'GPS: ${current.latitude}, ${current.longitude} | '
          'accuracy=${current.accuracy.toStringAsFixed(1)}m | '
          'segment=${segmentMeters.toStringAsFixed(1)}m | '
          'total=${distanceCoveredKm.toStringAsFixed(3)}km',
        );
      }

      _previousPosition = current;
      _setGpsPosition(current, addBillingPoint: false);

      if (mounted) setState(() {});

      await _moveCamera(LatLng(current.latitude, current.longitude));
    } catch (error) {
      debugPrint('Live GPS error: $error');
    }
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
    _gpsTimer?.cancel();
    _gpsTimer = null;
    _rideActive = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _gpsTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
