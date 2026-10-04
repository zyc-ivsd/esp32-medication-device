import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/ble/prototype_protocol.dart';
import 'package:medication_device_app/ble/prototype_store.dart';
import 'package:medication_device_app/ble/prototype_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class GatedStore implements PrototypeStore {
  final gate = Completer<void>();
  final rows = <PrototypeRecord>[];
  @override
  Future<void> save(PrototypeRecord record) async {
    await gate.future;
    rows.add(record);
  }

  @override
  Future<List<PrototypeRecord>> readRecent() async => rows;
  @override
  Future<List<PrototypeRecord>> readAll() => readRecent();
  @override
  Future<void> close() async {}
}

const token = '1234abcd';
const recordFrame =
    'R|$token|0|data_2026-08-29_22-30-00_1.txt|2026-08-29_22-30-00';
List<String> fields(String body) =>
    decodePrototypeFrame(encodePrototypeFrame(body).trim());

void main() {
  sqfliteFfiInit();
  test('CRC uses independent CCITT-FALSE check vector', () {
    expect(prototypeCrc(ascii.encode('123456789')), 0x29b1);
    expect(
      () => decodePrototypeFrame('READY|AABBCCDDEEFF|P01|0000'),
      throwsFormatException,
    );
  });
  test(
    'every split boundary and multiple frames preserve bytes, including UTF8',
    () {
      final message = encodePrototypeFrame('原型文本|测试');
      final bytes = utf8.encode(message);
      for (var split = 0; split <= bytes.length; split++) {
        final buffer = PrototypeLineBuffer();
        final lines = [
          ...buffer.add(bytes.sublist(0, split)),
          ...buffer.add(bytes.sublist(split)),
        ];
        expect(lines, [message.trim()]);
      }
      final buffer = PrototypeLineBuffer();
      expect(buffer.add(utf8.encode('$message$message')), hasLength(2));
    },
  );
  test('truncated and oversized lines recover on the next frame boundary', () {
    final buffer = PrototypeLineBuffer();
    buffer.add(List.filled(400, 65));
    final next = encodePrototypeFrame('END|$token|0');
    expect(buffer.add(utf8.encode(next)), [next.trim()]);
    buffer.add(ascii.encode('half a frame'));
    final lines = buffer.add(utf8.encode(next));
    expect(() => decodePrototypeFrame(lines.first), throwsFormatException);
    expect(decodePrototypeFrame(lines.last), ['END', token, '0']);
  });
  test(
    'ACK waits for persistence; duplicate ACK is safe; END and DONE are required',
    () async {
      final store = GatedStore();
      final writes = <String>[];
      final sync = PrototypeSync(
        deviceId: 'AABBCCDDEEFF',
        token: token,
        store: store,
        write: (value) async => writes.add(value),
        isActive: () => true,
      );
      await sync.accept(fields('BEGIN|$token|1'));
      expect(writes, ['START|$token']);
      final saving = sync.accept(fields(recordFrame));
      await Future<void>.delayed(Duration.zero);
      expect(writes, ['START|$token']);
      store.gate.complete();
      await saving;
      expect(writes.last, 'ACK|$token|0');
      await sync.accept(fields(recordFrame));
      expect(sync.savedCount, 1);
      await sync.accept(fields('END|$token|1'));
      expect(writes.last, 'COMMIT|$token');
      expect(sync.completed, false);
      await sync.accept(fields('DONE|$token'));
      expect(sync.completed, true);
    },
  );
  test('a failed database write never emits ACK or COMMIT', () async {
    final store = GatedStore();
    final writes = <String>[];
    final sync = PrototypeSync(
      deviceId: 'AABBCCDDEEFF',
      token: token,
      store: store,
      write: (value) async => writes.add(value),
      isActive: () => true,
    );
    await sync.accept(fields('BEGIN|$token|1'));
    final saving = sync.accept(fields(recordFrame));
    final expectation = expectLater(saving, throwsStateError);
    store.gate.completeError(StateError('disk full'));
    await expectation;
    expect(writes, ['START|$token']);
    await expectLater(
      sync.accept(fields('END|$token|1')),
      throwsFormatException,
    );
  });
  test(
    'disconnect during persistence never acknowledges the old connection',
    () async {
      var active = true;
      final store = GatedStore();
      final writes = <String>[];
      final sync = PrototypeSync(
        deviceId: 'AABBCCDDEEFF',
        token: token,
        store: store,
        write: (value) async => writes.add(value),
        isActive: () => active,
      );
      await sync.accept(fields('BEGIN|$token|1'));
      final saving = sync.accept(fields(recordFrame));
      active = false;
      store.gate.complete();
      await saving;
      expect(writes, ['START|$token']);
    },
  );
  test(
    'missing/out-of-order records, stale sessions and early DONE cannot commit',
    () async {
      final store = GatedStore()..gate.complete();
      final writes = <String>[];
      final sync = PrototypeSync(
        deviceId: 'AABBCCDDEEFF',
        token: token,
        store: store,
        write: (value) async => writes.add(value),
        isActive: () => true,
      );
      await sync.accept(fields('BEGIN|$token|2'));
      await sync.accept(fields(recordFrame.replaceFirst(token, 'ffffffff')));
      expect(sync.savedCount, 0);
      await expectLater(
        sync.accept(fields(recordFrame.replaceFirst('|0|', '|1|'))),
        throwsFormatException,
      );
      await expectLater(
        sync.accept(fields('END|$token|2')),
        throwsFormatException,
      );
      await expectLater(
        sync.accept(fields('DONE|$token')),
        throwsFormatException,
      );
      expect(writes, ['START|$token']);
    },
  );
  test('empty snapshots complete without inventing an event', () async {
    final store = GatedStore()..gate.complete();
    final writes = <String>[];
    final sync = PrototypeSync(
      deviceId: 'AABBCCDDEEFF',
      token: token,
      store: store,
      write: (value) async => writes.add(value),
      isActive: () => true,
    );
    await sync.accept(fields('BEGIN|$token|0'));
    await sync.accept(fields('END|$token|0'));
    await sync.accept(fields('DONE|$token'));
    expect(sync.completed, true);
    expect(store.rows, isEmpty);
    expect(writes, ['START|$token', 'COMMIT|$token']);
  });
  test(
    'raw SQLite survives reopen, deduplicates, and rejects changed file payload',
    () async {
      final dir = await Directory.systemTemp.createTemp('prototype-store-');
      final path = '${dir.path}/raw.db';
      Future<SqlitePrototypeStore> open() => SqlitePrototypeStore.open(
        factory: databaseFactoryFfiNoIsolate,
        path: path,
      );
      var store = await open();
      final record = PrototypeRecord(
        deviceId: 'AABBCCDDEEFF',
        fileId: 'data_test.txt',
        rawText: '2026-08-29_22-30-00',
        receivedAt: DateTime.utc(2026),
      );
      await store.save(record);
      await store.close();
      store = await open();
      await store.save(record);
      expect(await store.readRecent(), hasLength(1));
      await expectLater(
        store.save(
          PrototypeRecord(
            deviceId: record.deviceId,
            fileId: record.fileId,
            rawText: 'different',
            receivedAt: DateTime.now(),
          ),
        ),
        throwsStateError,
      );
      expect((await store.readRecent()).single.rawText, record.rawText);
      await store.close();
      await dir.delete(recursive: true);
    },
  );
}
