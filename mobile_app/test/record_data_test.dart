import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/database/record_repository.dart';
import 'package:medication_device_app/database/sqlite_record_repository.dart';
import 'package:medication_device_app/models/medication_record.dart';
import 'package:medication_device_app/models/record_filter.dart';
import 'package:medication_device_app/models/record_summary.dart';
import 'package:medication_device_app/services/csv_export_service.dart';
import 'package:medication_device_app/services/record_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MedicationRecord record(
        {int seq = 1,
        int timestamp = 0,
        int type = 1,
        String deviceId = 'device-a',
        int confidence = 92}) =>
    MedicationRecord(
        deviceId: deviceId,
        seq: seq,
        timestamp: timestamp,
        eventType: type,
        durationMs: 1200,
        pressurePeakPa: -84,
        confidence: confidence,
        batteryMv: 3700);
int unix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

void main() {
  sqfliteFfiInit();
  Future<SqliteRecordRepository> open(RecordSource source, [String? path]) =>
      SqliteRecordRepository.open(
        source: source,
        factory: databaseFactoryFfiNoIsolate,
        path: path ?? inMemoryDatabasePath,
      );

  test(
    'validates protocol field bounds and preserves an unknown timestamp',
    () {
      expect(() => record(seq: -1), throwsRangeError);
      expect(() => record(confidence: 101), throwsRangeError);
      expect(() => record(deviceId: ' '), throwsArgumentError);
      expect(() => record(type: 9), throwsRangeError);
      expect(record().occurredAt, isNull);
      expect(
        record().samePayload(MedicationRecord.fromMap(record().toMap())),
        isTrue,
      );
    },
  );

  test(
    'SQLite persists across reopen and returns duplicate without replacing data',
    () async {
      final dir = await Directory.systemTemp.createTemp('medication-reopen-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/records.db';
      var repo = await open(RecordSource.device, path);
      expect(
        await repo.saveValidatedRecord(record()),
        SaveRecordResult.inserted,
      );
      await repo.close();
      repo = await open(RecordSource.device, path);
      expect(
        await repo.saveValidatedRecord(record()),
        SaveRecordResult.duplicate,
      );
      final saved = await repo.readAll();
      expect(saved, hasLength(1));
      expect(saved.single.pressurePeakPa, -84);
      expect(saved.single.timestamp, 0);
      await repo.close();
    },
  );

  test(
    'same device/seq with a different payload fails instead of overwriting or ACKing',
    () async {
      final repo = await open(RecordSource.device);
      addTearDown(repo.close);
      await repo.saveValidatedRecord(record());
      await expectLater(
        repo.saveValidatedRecord(record(confidence: 40)),
        throwsA(isA<RecordConflictException>()),
      );
      expect((await repo.readAll()).single.confidence, 92);
      await repo.saveValidatedRecord(record(deviceId: 'device-b'));
      expect(await repo.readAll(), hasLength(2));
    },
  );

  test('a storage failure cannot reach the caller ACK step', () async {
    final repo = await open(RecordSource.device);
    await repo.close();
    var acknowledged = false;
    Future<void> receive() async {
      await repo.saveValidatedRecord(record());
      acknowledged = true;
    }

    await expectLater(receive(), throwsA(anything));
    expect(acknowledged, isFalse);
  });

  test(
    'cursor requires an explicit initial baseline and rejects gaps/backtracking',
    () async {
      final repo = await open(RecordSource.device);
      addTearDown(repo.close);
      await repo.saveValidatedRecord(record(seq: 1));
      await repo.saveValidatedRecord(record(seq: 3));
      expect(await repo.readSyncCursor('device-a'), isNull);
      await expectLater(
        repo.advanceSyncCursor('device-a', 3),
        throwsStateError,
      );
      await expectLater(
        repo.advanceSyncCursor('device-a', 3, firstSequence: 1),
        throwsStateError,
      );
      expect(await repo.readSyncCursor('device-a'), isNull);
      await repo.advanceSyncCursor('device-a', 1, firstSequence: 1);
      await expectLater(
        repo.advanceSyncCursor('device-a', 3),
        throwsStateError,
      );
      await repo.saveValidatedRecord(record(seq: 2));
      await repo.advanceSyncCursor('device-a', 3);
      expect(await repo.readSyncCursor('device-a'), 3);
      await expectLater(
        repo.advanceSyncCursor('device-a', 2),
        throwsStateError,
      );
    },
  );

  test(
    'sync cursor and completion time survive reopening the database',
    () async {
      final dir = await Directory.systemTemp.createTemp('medication-cursor-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/records.db';
      var repo = await open(RecordSource.device, path);
      final instant = DateTime.utc(2026, 9, 12, 3);
      await repo.saveValidatedRecord(record(seq: 0));
      await repo.advanceSyncCursor('device-a', 0, firstSequence: 0);
      await repo.markSyncCompleted(instant);
      await repo.close();
      repo = await open(RecordSource.device, path);
      expect(await repo.readSyncCursor('device-a'), 0);
      expect(await repo.lastSyncAt(), instant);
      await repo.close();
    },
  );

  test(
    'daily stats exclude unknown/future timestamps and separate event types',
    () {
      final now = DateTime(2026, 9, 12, 12);
      final records = [
        record(timestamp: unix(DateTime(2026, 9, 12))),
        record(seq: 2, timestamp: unix(DateTime(2026, 9, 6))),
        record(seq: 3, timestamp: unix(DateTime(2026, 9, 5, 23, 59))),
        record(seq: 4),
        record(seq: 5, timestamp: unix(DateTime(2026, 9, 12, 13))),
        record(seq: 6, type: 2, timestamp: unix(now)),
        record(seq: 7, type: 3, timestamp: unix(now)),
        record(seq: 8, type: 2),
      ];
      final summary = RecordSummary.calculate(records, now: now);
      expect(summary.total, 8);
      expect(summary.todayCount, 1);
      expect(summary.last7DaysCount, 2);
      expect(summary.invalidEventCount, 1);
      expect(summary.unknownTimeCount, 2);
      expect(summary.futureTimeCount, 1);
      expect(summary.days.map((day) => day.count).reduce((a, b) => a + b), 2);
      final context = summary.toAssistantContext();
      expect(context.toJson()['is_demo'], isFalse);
      expect(context.last7DaysCount, 2);
      expect(context.unknownTimeCount, 2);
      expect(context.totalCount, 8);
      expect(context.dailyCounts, hasLength(7));
      // Mirrors the gateway contract: the series must add up to the 7-day total.
      expect(context.dailyCounts.fold(0, (sum, count) => sum + count), 2);
    },
  );

  test(
    'local date filtering uses an exclusive end and explicit unknown-time switch',
    () {
      final filter = RecordFilter(
        start: DateTime(2026, 9, 12),
        endExclusive: DateTime(2026, 9, 13),
        includeUnknown: false,
      );
      expect(filter.accepts(unix(DateTime(2026, 9, 12))), isTrue);
      expect(filter.accepts(unix(DateTime(2026, 9, 12, 23, 59, 59))), isTrue);
      expect(filter.accepts(unix(DateTime(2026, 9, 13))), isFalse);
      expect(filter.accepts(0), isFalse);
      expect(const RecordFilter().accepts(0), isTrue);
    },
  );

  test(
    'CSV retains raw fields, quotes text and labels device data and unknown times',
    () {
      final csv = CsvExportService.encode([
        record(deviceId: '=SUM(1,2)'),
      ], RecordSource.device);
      expect(csv.startsWith('\uFEFF'), isTrue);
      expect(csv, contains('"device","\'=SUM(1,2)","1","0","","","unknown"'));
      expect(csv, contains('"1200","-84","92","3700","1",""'));
      expect(csv, isNot(contains('1970-')));
      expect(csv.split('\r\n'), hasLength(3));
      final quoted = CsvExportService.encode([
        record(deviceId: 'id,"quoted"'),
      ], RecordSource.device);
      expect(quoted, contains('"id,""quoted"""'));
    },
  );

  test(
    'controller observes device saves and filters the same device records',
    () async {
      final device = await open(RecordSource.device);
      final now = DateTime(2026, 9, 12, 12);
      final controller = RecordController(
        deviceRepository: device,
        clock: () => now,
      );
      addTearDown(() async {
        controller.dispose();
        await device.close();
      });
      await controller.refresh();
      expect(controller.records, isEmpty);
      expect(controller.summary!.total, 0);
      await device.saveValidatedRecord(record(timestamp: unix(now)));
      await device.saveValidatedRecord(record(seq: 2));
      await controller.refresh();
      expect(controller.source, RecordSource.device);
      expect(controller.summary!.todayCount, 1);
      expect(controller.summary!.total, 2);
      controller.setFilter(
        RecordFilter(
          start: DateTime(2026, 9, 12),
          endExclusive: DateTime(2026, 9, 13),
          includeUnknown: false,
        ),
      );
      expect(controller.visibleRecords, hasLength(1));
      expect(
        controller.visibleRecords.single.samePayload(
          (await device.readAll()).first,
        ),
        isTrue,
      );
    },
  );

  test(
    'legacy synthetic databases cannot be opened as device data and remain intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('medication-legacy-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/records_demo.db';
      final repo = await open(RecordSource.device, path);
      await repo.saveValidatedRecord(record());
      await repo.close();
      final legacy = await databaseFactoryFfiNoIsolate.openDatabase(path);
      await legacy.update(
        'metadata',
        {'value': 'demo'},
        where: 'key = ?',
        whereArgs: ['source'],
      );
      await legacy.close();
      await expectLater(open(RecordSource.device, path), throwsStateError);
      final preserved = await databaseFactoryFfiNoIsolate.openDatabase(path);
      expect(await preserved.query('records'), hasLength(1));
      expect(
        (await preserved.query(
          'metadata',
          where: 'key = ?',
          whereArgs: ['source'],
        )).single['value'],
        'demo',
      );
      await preserved.close();
    },
  );
}
