import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/ble_transport.dart';
import 'package:medication_device_app/ble/prototype_protocol.dart';
import 'package:medication_device_app/ble/prototype_store.dart';

class FakeBleTransport implements BleTransport {
  final states = StreamController<ConnectionStateUpdate>.broadcast();
  final packets = StreamController<List<int>>.broadcast();
  final devices = StreamController<DiscoveredDevice>.broadcast();
  final writes = <String>[];
  final order = <String>[];
  Completer<void>? readiness;
  bool subscribed = false;
  bool failSubscribe = false;
  int connections = 0;
  @override
  Future<void> ensureReady() async {
    await readiness?.future;
  }

  @override
  Stream<DiscoveredDevice> scan() => devices.stream;
  @override
  Stream<ConnectionStateUpdate> connect(String deviceId) {
    connections++;
    return states.stream;
  }

  @override
  Future<void> discover(String deviceId) async {
    order.add('discover');
  }

  @override
  Stream<List<int>> subscribe(String deviceId) {
    order.add('subscribe');
    subscribed = true;
    return failSubscribe
        ? Stream.error(StateError('Notify failed'))
        : packets.stream;
  }

  @override
  Future<void> write(String deviceId, List<int> bytes) async {
    expect(subscribed, true);
    expect(bytes.length, lessThanOrEqualTo(20));
    final command = utf8.decode(bytes);
    writes.add(command);
    order.add(command);
  }

  void state(DeviceConnectionState state) => states.add(
    ConnectionStateUpdate(
      deviceId: 'phone-link',
      connectionState: state,
      failure: null,
    ),
  );
  void frame(String body) {
    final bytes = utf8.encode(encodePrototypeFrame(body));
    for (var offset = 0; offset < bytes.length; offset += 20) {
      packets.add(bytes.sublist(offset, min(bytes.length, offset + 20)));
    }
  }

  Future<void> close() async {
    await states.close();
    await packets.close();
    await devices.close();
  }
}

class MemoryTextStore implements PrototypeStore {
  final rows = <String, PrototypeRecord>{};
  bool closed = false;
  @override
  Future<void> save(PrototypeRecord row) async {
    rows[row.fileId] = row;
  }

  @override
  Future<List<PrototypeRecord>> readRecent() async => rows.values.toList();
  @override
  Future<List<PrototypeRecord>> readAll() => readRecent();
  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for test event');
}

void main() {
  test(
    'lost initial HELLO retries; READY precedes request; data lands in raw SQLite contract',
    () async {
      final ble = FakeBleTransport();
      final store = MemoryTextStore();
      final service = BleService(
        transport: ble,
        store: store,
        usePreferences: false,
        handshakeInterval: const Duration(milliseconds: 20),
      );
      addTearDown(() async {
        service.dispose();
        await until(() => store.closed);
        await ble.close();
      });
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.length >= 2);
      expect(ble.order.take(3), ['discover', 'subscribe', 'HELLO']);
      expect(ble.writes.every((w) => w == 'HELLO'), true);
      ble.frame('READY|AABBCCDDEEFF|P01');
      // Legacy firmware offers REQ after READY; the app must not ask first.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), isEmpty);
      ble.frame('REQ|a1b2c3d4|1');
      await until(() => ble.writes.any((w) => w.startsWith('SYNC_REQ|')));
      final token = ble.writes
          .firstWhere((w) => w.startsWith('SYNC_REQ|'))
          .split('|')[1];
      expect(token, 'a1b2c3d4');
      ble.frame('BEGIN|$token|1');
      await until(() => ble.writes.contains('START|$token'));
      // Corruption receives no ACK; leading newline in a retry resynchronizes.
      ble.packets.add(ascii.encode('\nR|$token|0|corrupt|0000\n'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ble.writes.where((w) => w.startsWith('ACK')), isEmpty);
      ble.frame(
        'R|$token|0|data_6878f1c0_1.txt|0000000068b075c0',
      );
      await until(() => ble.writes.contains('ACK|$token|0'));
      expect(store.rows.length, 1);
      ble.frame('END|$token|1');
      await until(() => ble.writes.contains('COMMIT|$token'));
      expect(service.status, BleConnectionStatus.syncing);
      ble.frame('DONE|$token');
      await until(() => service.status == BleConnectionStatus.complete);
      expect(service.savedRecords.single.deviceId, 'AABBCCDDEEFF');
      expect(service.receivedBytes, greaterThan(20));
      expect(service.canSync, true);
    },
  );
  test(
    'subscription error cancels handshake and never requests data',
    () async {
      final ble = FakeBleTransport()..failSubscribe = true;
      final store = MemoryTextStore();
      final service = BleService(
        transport: ble,
        store: store,
        usePreferences: false,
        handshakeInterval: const Duration(milliseconds: 10),
      );
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => service.status == BleConnectionStatus.error);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ')), isEmpty);
      expect(ble.writes.length, lessThanOrEqualTo(1));
      service.dispose();
      await until(() => store.closed);
      await ble.close();
    },
  );
  test(
    'manual disconnect invalidates late READY and automatic reconnect',
    () async {
      final ble = FakeBleTransport();
      final store = MemoryTextStore();
      final service = BleService(
        transport: ble,
        store: store,
        usePreferences: false,
        handshakeInterval: const Duration(milliseconds: 10),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.isNotEmpty);
      ble.state(DeviceConnectionState.disconnected);
      await until(() => !service.hasConnection);
      await service.disconnect();
      final count = ble.writes.length;
      ble.frame('READY|AABBCCDDEEFF|P01');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ble.connections, 1);
      expect(ble.writes.length, count);
      service.dispose();
      await until(() => store.closed);
      await ble.close();
    },
  );
  test('cancel during permission dialog prevents a late scan', () async {
    final ble = FakeBleTransport()..readiness = Completer<void>();
    final service = BleService(transport: ble, usePreferences: false);
    final scan = service.startScan();
    await until(() => service.status == BleConnectionStatus.scanning);
    await service.cancelScan();
    ble.readiness!.complete();
    await scan;
    expect(ble.devices.hasListener, false);
    expect(service.status, BleConnectionStatus.disconnected);
    service.dispose();
    await ble.close();
  });
  test(
    'empty sync retries COMMIT if the first DONE notification was lost',
    () async {
      final ble = FakeBleTransport();
      final store = MemoryTextStore();
      final service = BleService(
        transport: ble,
        store: store,
        usePreferences: false,
      );
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.isNotEmpty);
      ble.frame('READY|AABBCCDDEEFF|P01');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(ble.writes.where((w) => w.startsWith('SYNC_REQ|')), isEmpty);
      ble.frame('REQ|a1b2c3d4|0');
      await until(() => ble.writes.any((w) => w.startsWith('SYNC_REQ|')));
      final token = ble.writes.last.split('|')[1];
      expect(token, 'a1b2c3d4');
      ble.frame('BEGIN|$token|0');
      await until(() => ble.writes.contains('START|$token'));
      ble.frame('END|$token|0');
      await until(() => ble.writes.contains('COMMIT|$token'));
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(ble.writes.where((w) => w == 'COMMIT|$token'), hasLength(2));
      ble.frame('DONE|$token');
      await until(() => service.status == BleConnectionStatus.complete);
      expect(store.rows, isEmpty);
      service.dispose();
      await until(() => store.closed);
      await ble.close();
    },
  );
  test(
    'a dropped link clears the outstanding offer so the next REQ is accepted',
    () async {
      // Regression: the device reconnects with a NEW token. If the app kept the
      // previous token, the fresh REQ looked like a duplicate and was silently
      // ignored, so the device retried forever and never got a SYNC_REQ.
      final ble = FakeBleTransport();
      final store = MemoryTextStore();
      final service = BleService(
        transport: ble,
        store: store,
        usePreferences: false,
        handshakeInterval: const Duration(milliseconds: 10),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        service.dispose();
        await until(() => store.closed);
        await ble.close();
      });
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.contains('HELLO'));
      ble.frame('READY|AABBCCDDEEFF|P01');
      // First offer is accepted but the link drops before any data arrives.
      ble.frame('REQ|aaaaaaaa|10');
      await until(() => ble.writes.contains('SYNC_REQ|aaaaaaaa'));

      // Manual disconnect runs _clearLink, the same path a dropped link takes.
      await service.disconnect();
      expect(
        service.hasPendingDeviceRequest,
        isFalse,
        reason: 'the stale offer token must not survive a link drop',
      );

      // Reconnect: the device offers a brand-new token and it must be accepted.
      await service.connectToDevice('phone-link');
      ble.state(DeviceConnectionState.connected);
      await until(() => ble.writes.where((w) => w == 'HELLO').length == 2);
      ble.frame('READY|AABBCCDDEEFF|P01');
      ble.frame('REQ|bbbbbbbb|10');
      await until(
        () => ble.writes.any((w) => w.startsWith('SYNC_REQ|bbbbbbbb')),
      );
      expect(
        ble.writes.where((w) => w == 'SYNC_REQ|bbbbbbbb'),
        hasLength(1),
        reason: 'the new offer must not be ignored as a duplicate',
      );
    },
  );
}
