import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_access.dart';

void main() {
  test(
    'iOS waits for CoreBluetooth and never calls Android permission APIs',
    () async {
      final events = StreamController<BleStatus>();
      var androidCalls = 0;
      final gate = BleAccessGate(
        platform: BleHostPlatform.ios,
        requestAndroidPermissions: () async {
          androidCalls++;
          return false;
        },
        currentStatus: () => BleStatus.unknown,
        statusChanges: () => events.stream,
      );
      final pending = gate.ensureReady();
      events.add(BleStatus.unknown);
      events.add(BleStatus.ready);
      await pending;
      expect(androidCalls, 0);
      await events.close();
    },
  );
  test(
    'denied iOS authorization offers app settings and can be retried after grant',
    () async {
      var status = BleStatus.unauthorized;
      final gate = BleAccessGate(
        platform: BleHostPlatform.ios,
        requestAndroidPermissions: () async =>
            throw StateError('Android must not run'),
        currentStatus: () => status,
        statusChanges: () => const Stream.empty(),
      );
      await expectLater(
        gate.ensureReady(),
        throwsA(
          isA<BleAccessException>().having(
            (e) => e.canOpenSettings,
            'settings recovery',
            true,
          ),
        ),
      );
      status = BleStatus.ready;
      await gate.ensureReady();
    },
  );
  test('powered-off iPhone does not report a permission error', () async {
    final gate = BleAccessGate(
      platform: BleHostPlatform.ios,
      requestAndroidPermissions: () async => true,
      currentStatus: () => BleStatus.poweredOff,
      statusChanges: () => const Stream.empty(),
    );
    await expectLater(
      gate.ensureReady(),
      throwsA(
        isA<BleAccessException>()
            .having(
              (e) => e.canOpenSettings,
              'not an app-permission fault',
              false,
            )
            .having(
              (e) => e.message,
              'actionable explanation',
              contains('Turn on Bluetooth'),
            ),
      ),
    );
  });
  test(
    'an unanswered authorization prompt times out with recovery instructions',
    () async {
      final gate = BleAccessGate(
        platform: BleHostPlatform.ios,
        requestAndroidPermissions: () async => true,
        currentStatus: () => BleStatus.unknown,
        statusChanges: () => const Stream.empty(),
        timeout: const Duration(milliseconds: 5),
      );
      // An open stream represents an unanswered system prompt.
      final events = StreamController<BleStatus>();
      final waiting = BleAccessGate(
        platform: gate.platform,
        requestAndroidPermissions: gate.requestAndroidPermissions,
        currentStatus: gate.currentStatus,
        statusChanges: () => events.stream,
        timeout: gate.timeout,
      );
      await expectLater(
        waiting.ensureReady(),
        throwsA(
          isA<BleAccessException>().having(
            (e) => e.message,
            'retry',
            contains('permission prompt'),
          ),
        ),
      );
      await events.close();
    },
  );
  test(
    'Android retains its permission gate before BLE initialization',
    () async {
      var consultedStatus = false;
      final gate = BleAccessGate(
        platform: BleHostPlatform.android,
        requestAndroidPermissions: () async => false,
        currentStatus: () {
          consultedStatus = true;
          return BleStatus.ready;
        },
        statusChanges: () => const Stream.empty(),
      );
      await expectLater(gate.ensureReady(), throwsA(isA<BleAccessException>()));
      expect(consultedStatus, false);
    },
  );
}
