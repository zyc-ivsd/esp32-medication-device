import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:medication_device_app/ble/ble_service.dart';
import 'package:medication_device_app/ble/prototype_protocol.dart';
import 'package:medication_device_app/ble/prototype_store.dart';
import 'package:medication_device_app/ble/prototype_sync.dart';
import 'package:medication_device_app/database/sqlite_record_repository.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/models/record_filter.dart';
import 'package:medication_device_app/models/record_summary.dart';
import 'package:medication_device_app/services/csv_export_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ble_service_test.dart' show FakeBleTransport, MemoryTextStore;

final _now = DateTime(2026, 10, 4, 12);

/// The device now sends 16 hex-digit UTC seconds. Tests express a wall-clock
/// local time and this helper converts it to the UTC instant the firmware would
/// record, so assertions stay readable and stable across host timezones.
String utcHex(DateTime localWallClock) =>
    (localWallClock.toUtc().millisecondsSinceEpoch ~/ 1000)
        .toRadixString(16)
        .padLeft(16, '0');

PrototypeRecord timestamp(
  String text, {
  String file = 'data_test_1.txt',
  String device = 'C3-A',
}) => PrototypeRecord(
  deviceId: device,
  fileId: file,
  rawText: text,
  receivedAt: _now,
);

Future<SqliteRecordRepository> open([String? path]) =>
    SqliteRecordRepository.open(
      source: RecordSource.device,
      factory: databaseFactoryFfiNoIsolate,
      path: path ?? inMemoryDatabasePath,
    );

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  sqfliteFfiInit();

  test(
    'device timestamps accept only 16 hex UTC seconds in 2001-2099',
    () {
      for (final raw in [
        'not-a-time',
        '2026-10-04_08-00-00', // legacy calendar text is no longer valid
        '00000000386d4380',    // 2000 placeholder is excluded
        '00000000f4865700',    // beyond 2099
        '386d4380',            // too short (legacy 8 hex)
        '00000000386d43800',   // too long
        '00000000386d438g',    // non-hex digit
        '',
      ]) {
        expect(parseDeviceTimestamp(raw), isNull, reason: raw);
      }
      final leap = parseDeviceTimestamp(utcHex(DateTime(2024, 2, 29, 8)))!;
      expect(leap.isUtc, isTrue);
      final local = leap.toLocal();
      expect([local.year, local.month, local.day, local.hour], [2024, 2, 29, 8]);
    },
  );

  test(
    'unique files count once; same-second presses and different devices remain distinct',
    () async {
      final repo = await open();
      addTearDown(repo.close);
      final first = timestamp(utcHex(DateTime(2026, 10, 4, 8)));
      await repo.saveDeviceTimestamp(first);
      await repo.saveDeviceTimestamp(
        PrototypeRecord(
          deviceId: first.deviceId,
          fileId: first.fileId,
          rawText: first.rawText,
          receivedAt: _now.add(const Duration(days: 1)),
        ),
      );
      await repo.saveDeviceTimestamp(
        timestamp(first.rawText, file: 'data_test_2.txt'),
      );
      await repo.saveDeviceTimestamp(timestamp(first.rawText, device: 'C3-B'));
      final records = await repo.readAll();
      expect(records, hasLength(3));
      final summary = RecordSummary.calculate(records, now: _now);
      expect(summary.todayCount, 3);
      expect(summary.last7DaysCount, 3);
      expect(records.first.durationMs, isNull);
      expect(records.first.pressurePeakPa, isNull);
      expect(records.first.confidence, isNull);
      expect(records.first.occurredAt, isNull);
      expect(
        records.first.samePayload(
          MedicationRecord.fromMap(records.first.toMap()),
        ),
        isTrue,
      );
    },
  );

  test(
    'conflicting file text is rejected without changing the saved use',
    () async {
      final repo = await open();
      addTearDown(repo.close);
      await repo.saveDeviceTimestamp(timestamp(utcHex(DateTime(2026, 10, 4, 8))));
      await expectLater(
        repo.saveDeviceTimestamp(timestamp(utcHex(DateTime(2026, 10, 4, 9)))),
        throwsStateError,
      );
      expect(
        (await repo.readAll()).single.rawTimestampText,
        utcHex(DateTime(2026, 10, 4, 8)),
      );
    },
  );

  test(
    'unknown, impossible and future times remain visible without inflating daily counts',
    () async {
      final repo = await open();
      addTearDown(repo.close);
      for (final (index, raw) in [
        utcHex(DateTime(2026, 10, 4, 8)),
        utcHex(DateTime(2000, 1, 1, 0, 0, 10)),
        utcHex(DateTime(2026, 10, 5, 8)),
        utcHex(DateTime(2026, 9, 28, 8)),
      ].indexed) {
        await repo.saveDeviceTimestamp(
          timestamp(raw, file: 'data_test_$index.txt'),
        );
      }
      final records = await repo.readAll();
      final summary = RecordSummary.calculate(records, now: _now);
      expect(summary.total, 4);
      expect(summary.todayCount, 1);
      expect(summary.last7DaysCount, 2);
      expect(summary.unknownTimeCount, 1);
      expect(summary.futureTimeCount, 1);
      expect(summary.days.map((day) => day.count).reduce((a, b) => a + b), 2);
      final filter = RecordFilter(
        start: DateTime(2026, 10, 4),
        endExclusive: DateTime(2026, 10, 5),
        includeUnknown: false,
      );
      expect(
        records.where((row) => filter.acceptsLocalTime(row.localOccurredAt)),
        hasLength(1),
      );
    },
  );

  test(
    'CSV preserves device wall time and identity without invented UTC or measurements',
    () async {
      final repo = await open();
      addTearDown(repo.close);
      await repo.saveDeviceTimestamp(timestamp(utcHex(DateTime(2026, 10, 4, 8, 15, 32))));
      final csv = CsvExportService.encode(
        await repo.readAll(),
        RecordSource.device,
      );
      final lines = csv.trim().split('\r\n');
      final headers = lines[0]
          .replaceAll('\uFEFF', '')
          .split(',')
          .map((cell) => cell.replaceAll('"', ''))
          .toList();
      final values = lines[1]
          .split(',')
          .map((cell) => cell.replaceAll('"', ''))
          .toList();
      final row = Map.fromIterables(headers, values);
      final expectedUtc = DateTime(2026, 10, 4, 8, 15, 32).toUtc();
      expect(row['occurred_at_utc'], expectedUtc.toIso8601String());
      expect(
        row['timestamp_unix_seconds'],
        '${expectedUtc.millisecondsSinceEpoch ~/ 1000}',
      );
      expect(row['occurred_at_local'], expectedUtc.toLocal().toIso8601String());
      expect(row['duration_ms'], '');
      expect(row['pressure_peak_pa'], '');
      expect(row['confidence'], '');
      expect(row['device_file_id'], 'data_test_1.txt');
      expect(row['time_basis'], 'unix_utc');
    },
  );

  test(
    'backfill reads all retained records, beyond the recent 100, and is idempotent',
    () async {
      final raw = await SqlitePrototypeStore.open(
        factory: databaseFactoryFfiNoIsolate,
        path: inMemoryDatabasePath,
      );
      final repo = await open();
      addTearDown(raw.close);
      addTearDown(repo.close);
      for (var i = 0; i < 111; i++) {
        await raw.save(
          timestamp(utcHex(DateTime(2026, 10, 4, 8)), file: 'data_old_$i.txt'),
        );
      }
      expect(await raw.readRecent(), hasLength(100));
      final sink = RecordingPrototypeStore(raw, repo.saveDeviceTimestamp);
      await sink.backfill();
      await sink.backfill();
      expect(await repo.readAll(), hasLength(111));
    },
  );

  test(
    'ACK waits for the diary write; an interrupted projection can be repaired',
    () async {
      final raw = MemoryTextStore();
      final repo = await open();
      addTearDown(repo.close);
      final gate = Completer<void>();
      final writes = <String>[];
      final sink = RecordingPrototypeStore(raw, (record) async {
        await gate.future;
        await repo.saveDeviceTimestamp(record);
      });
      final sync = PrototypeSync(
        deviceId: 'C3-A',
        token: '12345678',
        store: sink,
        write: (text) async => writes.add(text),
        isActive: () => true,
      );
      await sync.accept(['BEGIN', '12345678', '1']);
      final pending = sync.accept([
        'R',
        '12345678',
        '0',
        'data_test_1.txt',
        utcHex(DateTime(2026, 10, 4, 8)),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(raw.rows, hasLength(1));
      expect(writes, ['START|12345678']);
      gate.complete();
      await pending;
      expect(writes.last, 'ACK|12345678|0');
      expect(await repo.readAll(), hasLength(1));
      final failed = RecordingPrototypeStore(
        raw,
        (_) async => throw StateError('disk full'),
      );
      final interrupted = PrototypeSync(
        deviceId: 'C3-A',
        token: '87654321',
        store: failed,
        write: (text) async => writes.add(text),
        isActive: () => true,
      );
      await interrupted.accept(['BEGIN', '87654321', '1']);
      await expectLater(
        interrupted.accept([
          'R',
          '87654321',
          '0',
          'data_test_2.txt',
          utcHex(DateTime(2026, 10, 4, 9)),
        ]),
        throwsStateError,
      );
      expect(writes, isNot(contains('ACK|87654321|0')));
      await RecordingPrototypeStore(raw, repo.saveDeviceTimestamp).backfill();
      expect(await repo.readAll(), hasLength(2));
    },
  );

  test(
    'v1 database upgrade preserves device events, cursors and sync metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('parcel-migration-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/records_device.db';
      final db = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE records (device_id TEXT, seq INTEGER, timestamp INTEGER, event_type INTEGER, duration_ms INTEGER, pressure_peak_pa INTEGER, confidence INTEGER, battery_mv INTEGER, protocol_version INTEGER, algorithm_version TEXT, PRIMARY KEY(device_id, seq))',
            );
            await db.execute(
              'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE sync_cursors (device_id TEXT PRIMARY KEY, seq INTEGER NOT NULL)',
            );
            await db.insert('metadata', {'key': 'source', 'value': 'device'});
            await db.insert('metadata', {
              'key': 'last_sync_at',
              'value': _now.toUtc().toIso8601String(),
            });
            await db.insert('sync_cursors', {'device_id': 'C3-A', 'seq': 17});
            await db.insert(
              'records',
              MedicationRecord(
                deviceId: 'C3-A',
                seq: 17,
                timestamp: 0,
                eventType: 1,
                durationMs: 1200,
                pressurePeakPa: -84,
                confidence: 92,
                batteryMv: 3700,
              ).toMap(),
            );
          },
        ),
      );
      await db.close();
      var repo = await open(path);
      expect(await repo.readSyncCursor('C3-A'), 17);
      expect(await repo.lastSyncAt(), _now.toUtc());
      await repo.saveDeviceTimestamp(timestamp(utcHex(DateTime(2026, 10, 4, 8))));
      await repo.close();
      repo = await open(path);
      expect(await repo.readAll(), hasLength(2));
      expect(
        (await repo.readAll())
            .where((row) => !row.isTimestampRecord)
            .single
            .confidence,
        92,
      );
      await repo.close();
    },
  );

  test(
    'BLE frames reach the diary and update freshness only after DONE',
    () async {
      final transport = FakeBleTransport();
      final repo = await open();
      final service = BleService(
        transport: transport,
        store: MemoryTextStore(),
        usePreferences: false,
        clock: () => _now,
      );
      addTearDown(() async {
        service.dispose();
        await transport.close();
        await repo.close();
      });
      await service.attachRecordSink(
        save: repo.saveDeviceTimestamp,
        markSyncCompleted: repo.markSyncCompleted,
      );
      await service.connectToDevice('phone-link');
      transport.state(DeviceConnectionState.connected);
      await until(() => transport.writes.contains('HELLO'));
      transport.frame('READY|AABBCCDDEEFF|P01');
      // The device initiates the transfer; the app only consents after REQ.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        transport.writes.where((value) => value.startsWith('SYNC_REQ|')),
        isEmpty,
      );
      transport.frame('REQ|12345678|1');
      await until(
        () => transport.writes.any((value) => value.startsWith('SYNC_REQ|')),
      );
      final token = transport.writes
          .lastWhere((value) => value.startsWith('SYNC_REQ|'))
          .split('|')
          .last;
      expect(token, '12345678');
      transport.frame('BEGIN|$token|1');
      await until(() => transport.writes.contains('START|$token'));
      transport.frame('R|$token|0|data_test_1.txt|${utcHex(DateTime(2026, 10, 4, 8))}');
      await until(() => transport.writes.contains('ACK|$token|0'));
      expect((await repo.readAll()).single.localOccurredAt, DateTime(2026, 10, 4, 8).toLocal());
      transport.frame('END|$token|1');
      await until(() => transport.writes.contains('COMMIT|$token'));
      expect(await repo.lastSyncAt(), isNull);
      transport.frame('DONE|$token');
      await until(() => service.status == BleConnectionStatus.complete);
      expect(await repo.lastSyncAt(), _now.toUtc());
    },
  );
}
