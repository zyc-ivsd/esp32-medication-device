import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

enum BleHostPlatform { android, ios, unsupported }

class BleAccessException implements Exception {
  const BleAccessException(this.message, {this.canOpenSettings = false});
  final String message;
  final bool canOpenSettings;
  @override
  String toString() => message;
}

/// iOS permission comes from CoreBluetooth initialization, never Android's
/// runtime permissions or the Android-only SDK version MethodChannel.
class BleAccessGate {
  BleAccessGate({
    required this.platform,
    required this.requestAndroidPermissions,
    required this.currentStatus,
    required this.statusChanges,
    this.timeout = const Duration(seconds: 30),
  });
  final BleHostPlatform platform;
  final Future<bool> Function() requestAndroidPermissions;
  final BleStatus Function() currentStatus;
  final Stream<BleStatus> Function() statusChanges;
  final Duration timeout;

  Future<void> ensureReady() async {
    if (platform == BleHostPlatform.unsupported) {
      throw const BleAccessException(
        'Use an Android phone with Bluetooth support',
      );
    }
    if (platform == BleHostPlatform.android &&
        !await requestAndroidPermissions()) {
      throw const BleAccessException(
        'Allow Bluetooth access. Android 11 and earlier also need location access.',
        canOpenSettings: true,
      );
    }
    var status = currentStatus();
    if (status == BleStatus.unknown) {
      try {
        status = await statusChanges()
            .firstWhere((s) => s != BleStatus.unknown)
            .timeout(timeout);
      } on TimeoutException {
        throw const BleAccessException(
          'Bluetooth is not ready. Complete the system permission prompt and scan again.',
        );
      }
    }
    if (status == BleStatus.ready) return;
    throw BleAccessException(switch (status) {
      BleStatus.poweredOff =>
        'Turn on Bluetooth in system settings, then return to scan.',
      BleStatus.unauthorized =>
        'Bluetooth permission was denied. Enable it in app settings.',
      BleStatus.locationServicesDisabled =>
        'Older Android versions need system location enabled to scan.',
      BleStatus.unsupported => 'This device does not support BLE.',
      _ => 'Bluetooth is not ready. Please try again.',
    }, canOpenSettings: status == BleStatus.unauthorized);
  }
}
