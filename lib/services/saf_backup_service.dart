import 'package:flutter/services.dart';

/// Best-effort Flutter wrapper for the Android Storage Access Framework backup.
class SafBackupService {
  SafBackupService._();

  static const MethodChannel _channel =
      MethodChannel('yatri_cabs/ride_service');
  static const String rideBackupFileName = 'active_ride_backup.json';

  static Future<bool> hasBackupFolder() async {
    try {
      return await _channel.invokeMethod<bool>('hasBackupFolder') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> pickBackupFolder() async {
    try {
      return await _channel.invokeMethod<bool>('pickBackupFolder') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> writeFile(String fileName, String content) async {
    try {
      return await _channel.invokeMethod<bool>(
            'writeBackupFile',
            <String, dynamic>{'fileName': fileName, 'content': content},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> readFile(String fileName) async {
    try {
      return await _channel.invokeMethod<String>(
        'readBackupFile',
        <String, dynamic>{'fileName': fileName},
      );
    } catch (_) {
      return null;
    }
  }
}
