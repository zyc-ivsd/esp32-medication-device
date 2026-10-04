import 'dart:convert';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';

import 'ble_service_test.dart' show FakeBleTransport, MemoryTextStore, until;

class OffsetClock implements DateTime {
  OffsetClock(this.utc, this.offset);
  final DateTime utc;
  final int offset;
  @override
  int get millisecondsSinceEpoch => utc.millisecondsSinceEpoch;
  @override
  Duration get timeZoneOffset => Duration(minutes: offset);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeBleTransport ble;
  late MemoryTextStore store;
  late BleService service;
  late DateTime phoneTime;
  setUp(() {
    ble = FakeBleTransport();
    store = MemoryTextStore();
    phoneTime = OffsetClock(DateTime.utc(2026, 10, 3, 12), 480);
    service = BleService(
      transport: ble,
      store: store,
      usePreferences: false,
      clock: () => phoneTime,
      clockRetryInterval: const Duration(milliseconds: 40),
      reconnectDelay: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    service.dispose();
    await until(() => store.closed);
    await ble.close();
  });
  Future<void> connect({bool timeCapable = true}) async {
    await service.connectToDevice('phone-link');
    ble.state(DeviceConnectionState.connected);
    await until(() => ble.writes.contains('HELLO'));
    ble.frame('READY|AABBCCDDEEFF|P01${timeCapable ? '|TIME1' : ''}');
    await until(
      () => ble.writes.any(
        (w) => w.startsWith(timeCapable ? 'TIME|' : 'SYNC_REQ|'),
      ),
    );
  }

  String timeCommand() => ble.writes.lastWhere((w) => w.startsWith('TIME|'));
  void acknowledgeClock([String? command]) =>
      ble.frame('TIME_OK|${(command ?? timeCommand()).substring(5)}');
  Future<void> completeEmptySync() async {
    await until(() => ble.writes.any((w) => w.startsWith('SYNC_REQ|')));
    final token = ble.writes
        .lastWhere((w) => w.startsWith('SYNC_REQ|'))
        .split('|')[1];
    ble.frame('BEGIN|$token|0');
    await until(() => ble.writes.contains('START|$token'));
    ble.frame('END|$token|0');
    await until(() => ble.writes.contains('COMMIT|$token'));
    ble.frame('DONE|$token');
    await until(() => service.status == BleConnectionStatus.complete);
  }

  test(
    'TIME1 calibrates with UTC and phone offset before requesting files',
    () async {
      await connect();
      final expected = (phoneTime.millisecondsSinceEpoch ~/ 1000).toRadixString(
        16,
      );
      expect(timeCommand(), 'TIME|$expected|480');
      expect(utf8.encode(timeCommand()).length, lessThanOrEqualTo(20));
      expect(service.status, BleConnectionStatus.calibrating);
      expect(service.canSync, false);
      await service.requestSync();
      // A corrupt frame, a wrong offset and an unframed legacy reply are not confirmations.
      ble.packets.add(utf8.encode('\nTIME_OK|$expected|480|0000\n'));
      ble.frame('TIME_OK|$expected|0');
      ble.packets.add(utf8.encode('\nTIME_OK\n'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), isEmpty);
      acknowledgeClock();
      await completeEmptySync();
      expect(service.clockStatus, ClockCalibrationStatus.synced);
      expect(service.lastClockCalibrationAt, same(phoneTime));
      expect(service.canCalibrateClock, true);
    },
  );

  test(
    'lost TIME_OK retries then stops without requesting or acknowledging files',
    () async {
      await connect();
      await until(() => service.status == BleConnectionStatus.error);
      expect(ble.writes.where((w) => w.startsWith('TIME|')), hasLength(3));
      expect(
        ble.writes.where(
          (w) => w.startsWith('SYNC_REQ|') || w.startsWith('ACK|'),
        ),
        isEmpty,
      );
      expect(service.clockStatus, ClockCalibrationStatus.failed);
      expect(service.canSync, false);
      expect(service.canCalibrateClock, true);
      expect(service.lastError, contains('calibration timed out'));
    },
  );

  test(
    'clock retry uses the same command and matching confirmation cancels timer',
    () async {
      await connect();
      final original = timeCommand();
      await until(() => ble.writes.where((w) => w == original).length == 2);
      acknowledgeClock(original);
      await completeEmptySync();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ble.writes.where((w) => w.startsWith('TIME|')).toList(), [
        original,
        original,
      ]);
    },
  );

  test(
    'device clock error permits retry and stale TIME_OK cannot complete a new request',
    () async {
      await connect();
      final original = timeCommand();
      ble.frame('TIME_ERR|CLOCK_STORAGE');
      await until(() => service.clockStatus == ClockCalibrationStatus.failed);
      expect(service.lastError, contains('CLOCK_STORAGE'));
      expect(service.canSync, false);
      phoneTime = OffsetClock(DateTime.utc(2026, 10, 3, 12, 1), -720);
      await service.requestClockCalibration(syncAfter: true);
      expect(timeCommand(), endsWith('|-720'));
      acknowledgeClock(original);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(service.clockStatus, ClockCalibrationStatus.pending);
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), isEmpty);
      acknowledgeClock();
      await completeEmptySync();
    },
  );

  test(
    'manual disconnect cancels calibration retry and discards late time replies',
    () async {
      await connect();
      final command = timeCommand();
      await service.disconnect();
      final count = ble.writes.length;
      acknowledgeClock(command);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ble.writes.length, count);
      expect(service.clockStatus, ClockCalibrationStatus.unavailable);
      expect(service.canCalibrateClock, false);
    },
  );

  test(
    'background pauses pending clock work and foreground requires a fresh handshake',
    () async {
      await connect();
      await service.setForeground(false);
      final count = ble.writes.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ble.writes.length, count);
      await service.setForeground(true);
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.where((w) => w == 'HELLO').length == 2);
      ble.frame('READY|AABBCCDDEEFF|P01|TIME1');
      await until(
        () => ble.writes.where((w) => w.startsWith('TIME|')).length == 2,
      );
      acknowledgeClock();
      await completeEmptySync();
    },
  );

  test('invalid phone clock stops calibration and data request', () async {
    phoneTime = DateTime.utc(1999, 12, 31);
    await service.connectToDevice('phone-link');
    ble.state(DeviceConnectionState.connected);
    await until(() => ble.writes.contains('HELLO'));
    ble.frame('READY|AABBCCDDEEFF|P01|TIME1');
    await until(() => service.status == BleConnectionStatus.error);
    expect(
      ble.writes.where(
        (w) => w.startsWith('TIME|') || w.startsWith('SYNC_REQ|'),
      ),
      isEmpty,
    );
    expect(service.lastError, contains('Phone date or timezone'));
  });

  test(
    'older P01 firmware still synchronizes with an explicit unsupported clock state',
    () async {
      await connect(timeCapable: false);
      expect(service.clockStatus, ClockCalibrationStatus.unsupported);
      expect(service.canCalibrateClock, false);
      expect(ble.writes.where((w) => w.startsWith('TIME|')), isEmpty);
      await completeEmptySync();
    },
  );

  test(
    'manual calibration is disabled during sync and available after DONE',
    () async {
      await connect();
      acknowledgeClock();
      await until(() => service.status == BleConnectionStatus.syncing);
      expect(service.canCalibrateClock, false);
      await service.requestClockCalibration();
      expect(ble.writes.where((w) => w.startsWith('TIME|')), hasLength(1));
      await completeEmptySync();
      phoneTime = DateTime.utc(2026, 10, 3, 13);
      await service.requestClockCalibration();
      acknowledgeClock();
      await until(() => service.clockStatus == ClockCalibrationStatus.synced);
      expect(service.status, BleConnectionStatus.ready);
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), hasLength(1));
      expect(service.canSync, true);
    },
  );
}
