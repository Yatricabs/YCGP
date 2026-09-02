package com.yatricabs.gpsbilling

import io.flutter.embedding.android.FlutterActivity

// Battery-optimization exemption is requested from the Dart side
// (main.dart's _requestBatteryOptimizationExemption / the persistent
// in-app banner) with driver-facing context and a verified check -
// this used to also auto-launch a Settings.ACTION_REQUEST_IGNORE_
// BATTERY_OPTIMIZATIONS intent unconditionally on every onCreate() from
// here, with zero context. That duplicated (and could race against) the
// Dart-side flow, and unprompted OEM Settings-intent launches are
// exactly the pattern that was already found to crash the app on a real
// Xiaomi/MIUI device via a different plugin - so this native path was
// removed rather than guarded, to eliminate that whole class of risk.
class MainActivity : FlutterActivity()
