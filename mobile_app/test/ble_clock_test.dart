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
      () => ble.writes.any((w) => w.startsWith(timeCapable ? 'TM|' : 'HELLO')),
    );
  }

  /// Device-initiated offer. The app only replies SYNC_REQ after this frame,
  /// mirroring the firmware sending REQ once the clock is settled.
  void offerSync([String token = 'a1b2c3d4', int count = 0]) =>
      ble.frame('REQ|$token|$count');

  String timeCommand() => ble.writes.lastWhere((w) => w.startsWith('TM|'));
  void acknowledgeClock([String? command]) =>
      ble.frame('TOK|${(command ?? timeCommand()).substring(3)}');
  Future<void> completeEmptySync() async {
    // The device offers REQ after a confirmed TOK; the app consents.
    offerSync();
    await until(() => ble.writes.any((w) => w.startsWith('SYNC_REQ|')));
    final token = ble.writes
        .lastWhere((w) => w.startsWith('SYNC_REQ|'))
        .split('|')[1];
    expect(token, 'a1b2c3d4');
    ble.frame('BEGIN|$token|0');
    await until(() => ble.writes.contains('START|$token'));
    ble.frame('END|$token|0');
    await until(() => ble.writes.contains('COMMIT|$token'));
    ble.frame('DONE|$token');
    await until(() => service.status == BleConnectionStatus.complete);
  }

  test(
    'TIME1 calibrates with UTC only, then waits for the device to offer files',
    () async {
      await connect();
      final expected = (phoneTime.millisecondsSinceEpoch ~/ 1000)
          .toRadixString(16)
          .padLeft(16, '0');
      expect(timeCommand(), 'TM|$expected');
      expect(utf8.encode(timeCommand()).length, lessThanOrEqualTo(20));
      expect(service.status, BleConnectionStatus.calibrating);
      expect(service.canSync, false);
      // The device drives sync, so a user tap while calibrating is ignored.
      await service.requestSync();
      expect(service.waitingForDeviceRequest, false);
      // A corrupt frame, an offset-bearing legacy reply and an unframed reply
      // are not confirmations.
      ble.packets.add(utf8.encode('\nTOK|$expected|480|0000\n'));
      ble.frame('TOK|$expected|0');
      ble.packets.add(utf8.encode('\nTOK\n'));
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
    'lost TOK retries then stops without requesting or acknowledging files',
    () async {
      await connect();
      await until(() => service.status == BleConnectionStatus.error);
      expect(ble.writes.where((w) => w.startsWith('TM|')), hasLength(3));
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
      expect(ble.writes.where((w) => w.startsWith('TM|')).toList(), [
        original,
        original,
      ]);
    },
  );

  test(
    'device clock error permits retry and stale TOK cannot complete a new request',
    () async {
      await connect();
      final original = timeCommand();
      ble.frame('TER|CLOCK_STORAGE');
      await until(() => service.clockStatus == ClockCalibrationStatus.failed);
      expect(service.lastError, contains('CLOCK_STORAGE'));
      expect(service.canSync, false);
      phoneTime = OffsetClock(DateTime.utc(2026, 10, 3, 12, 1), -720);
      await service.requestClockCalibration();
      // The offset must not appear on the wire: only UTC hex seconds are sent.
      expect(timeCommand(), startsWith('TM|'));
      expect(timeCommand().length, 19); // TM| + 16 hex digits
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
        () => ble.writes.where((w) => w.startsWith('TM|')).length == 2,
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
        (w) => w.startsWith('TM|') || w.startsWith('SYNC_REQ|'),
      ),
      isEmpty,
    );
    expect(service.lastError, contains('Phone date is out of range'));
  });

  test(
    'older P01 firmware still synchronizes with an explicit unsupported clock state',
    () async {
      await connect(timeCapable: false);
      await until(
        () => service.clockStatus == ClockCalibrationStatus.unsupported,
      );
      expect(service.canCalibrateClock, false);
      expect(ble.writes.where((w) => w.startsWith('TM|')), isEmpty);
      await completeEmptySync();
    },
  );

  test(
    'manual calibration is disabled during sync and available after DONE',
    () async {
      await connect();
      acknowledgeClock();
      // Device offers after TOK; the app consents and starts receiving.
      offerSync();
      await until(() => service.status == BleConnectionStatus.syncing);
      expect(service.canCalibrateClock, false);
      await service.requestClockCalibration();
      expect(ble.writes.where((w) => w.startsWith('TM|')), hasLength(1));
      await completeEmptySync();
      expect(service.canCalibrateClock, true);
      phoneTime = DateTime.utc(2026, 10, 3, 13);
      await service.requestClockCalibration();
      expect(ble.writes.where((w) => w.startsWith('TM|')), hasLength(2));
      acknowledgeClock();
      await until(() => service.clockStatus == ClockCalibrationStatus.synced);
      expect(service.status, BleConnectionStatus.ready);
      expect(service.canSync, true);
      // A calibration-only retry must not start a new transfer by itself.
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), hasLength(1));
    },
  );
}
