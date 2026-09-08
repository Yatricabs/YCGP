import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

abstract final class AppColors {
  static const Color green = Color(0xFF58B436);
  static const Color background = Color(0xFFFFF9FF);
  static const Color dark = Color(0xFF343434);
}

abstract final class RideConfig {
  static const double estimatedKm = 291.0;
  static const LatLng fallbackLocation = LatLng(26.8467, 80.9462);
}
