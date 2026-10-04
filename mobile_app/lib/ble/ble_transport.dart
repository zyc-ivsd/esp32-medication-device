import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_access.dart';

const prototypeServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const prototypeCharacteristicUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

abstract interface class BleTransport {
  Future<void> ensureReady();
  Stream<DiscoveredDevice> scan();
  Stream<ConnectionStateUpdate> connect(String deviceId);
  Future<void> discover(String deviceId);
  Stream<List<int>> subscribe(String deviceId);
  Future<void> write(String deviceId, List<int> bytes);
}

class ReactiveBleTransport implements BleTransport {
  ReactiveBleTransport({FlutterReactiveBle? ble})
    : _ble = ble ?? FlutterReactiveBle();
  final FlutterReactiveBle _ble;
  QualifiedCharacteristic _characteristic(String deviceId) =>
      QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: Uuid.parse(prototypeServiceUuid),
        characteristicId: Uuid.parse(prototypeCharacteristicUuid),
      );

  @override
  Future<void> ensureReady() => BleAccessGate(
    platform: Platform.isIOS
        ? BleHostPlatform.ios
        : Platform.isAndroid
        ? BleHostPlatform.android
        : BleHostPlatform.unsupported,
    currentStatus: () => _ble.status,
    statusChanges: () => _ble.statusStream,
    requestAndroidPermissions: () async {
      final sdk = await const MethodChannel(
        'org.igem.medication/platform',
      ).invokeMethod<int>('androidSdkInt');
      if (sdk == null) throw StateError('Cannot read the Android version');
      final permissions = sdk >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
      final result = await permissions.request();
      return result.values.every((value) => value.isGranted);
    },
  ).ensureReady();

  @override
  Stream<DiscoveredDevice> scan() =>
      _ble.scanForDevices(withServices: [Uuid.parse(prototypeServiceUuid)]);
  @override
  Stream<ConnectionStateUpdate> connect(String deviceId) =>
      _ble.connectToDevice(
        id: deviceId,
        connectionTimeout: const Duration(seconds: 15),
        servicesWithCharacteristicsToDiscover: {
          Uuid.parse(prototypeServiceUuid): [
            Uuid.parse(prototypeCharacteristicUuid),
          ],
        },
      );
  @override
  Future<void> discover(String deviceId) async {
    await _ble.discoverAllServices(deviceId);
    final services = await _ble.getDiscoveredServices(deviceId);
    final matches = services
        .where((s) => s.id == Uuid.parse(prototypeServiceUuid))
        .expand((s) => s.characteristics)
        .where((c) => c.id == Uuid.parse(prototypeCharacteristicUuid));
    if (matches.isEmpty ||
        !matches.first.isNotifiable ||
        !matches.first.isWritableWithResponse) {
      throw StateError(
        'The firmware is missing the required Write + Notify characteristic. Install the matching firmware.',
      );
    }
  }

  @override
  Stream<List<int>> subscribe(String deviceId) =>
      _ble.subscribeToCharacteristic(_characteristic(deviceId));
  @override
  Future<void> write(String deviceId, List<int> bytes) => _ble
      .writeCharacteristicWithResponse(_characteristic(deviceId), value: bytes);
}
