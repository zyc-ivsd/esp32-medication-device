import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/medication_record.dart';
import 'record_repository.dart';

class SqliteRecordRepository implements RecordRepository {
  SqliteRecordRepository._(this._db, this.source);

  final Database _db;
  @override
  final RecordSource source;
  final _changes = StreamController<void>.broadcast();

  static Future<SqliteRecordRepository> open({
    required RecordSource source,
    DatabaseFactory? factory,
    String? path,
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final dbPath = path ??
        p.join(await dbFactory.getDatabasesPath(), 'records_${source.name}.db');
    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onConfigure: (db) async {
          await db.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (db, version) async {
          await db.execute('''CREATE TABLE records (
            device_id TEXT NOT NULL,
            seq INTEGER NOT NULL CHECK(seq BETWEEN 0 AND 4294967295),
            timestamp INTEGER NOT NULL CHECK(timestamp BETWEEN 0 AND 4294967295),
            event_type INTEGER NOT NULL CHECK(event_type BETWEEN 1 AND 3),
            duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 0 AND 65535),
            pressure_peak_pa INTEGER NOT NULL CHECK(pressure_peak_pa BETWEEN -32768 AND 32767),
            confidence INTEGER NOT NULL CHECK(confidence BETWEEN 0 AND 100),
            battery_mv INTEGER NOT NULL CHECK(battery_mv BETWEEN 0 AND 65535),
            protocol_version INTEGER NOT NULL CHECK(protocol_version = 1),
            algorithm_version TEXT,
            PRIMARY KEY(device_id, seq)
          )''');
          await db.execute('CREATE INDEX records_time ON records(timestamp)');
          await db.execute(
              'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await db.execute(
              'CREATE TABLE sync_cursors (device_id TEXT PRIMARY KEY, seq INTEGER NOT NULL)');
          await db.insert('metadata', {'key': 'source', 'value': source.name});
        },
      ),
    );
    final dataset =
        await db.query('metadata', where: 'key = ?', whereArgs: ['source']);
    if (dataset.single['value'] != source.name) {
      await db.close();
      throw StateError('Database dataset does not match ${source.name}');
    }
    return SqliteRecordRepository._(db, source);
  }

  @override
  Stream<void> get changes => _changes.stream;

  Future<SaveRecordResult> _save(
      Transaction txn, MedicationRecord record) async {
    final previous = await txn.query('records',
        where: 'device_id = ? AND seq = ?',
        whereArgs: [record.deviceId, record.seq]);
    if (previous.isNotEmpty) {
      if (!record.samePayload(MedicationRecord.fromMap(previous.single))) {
        throw RecordConflictException(record.deviceId, record.seq);
      }
      return SaveRecordResult.duplicate;
    }
    await txn.insert('records', record.toMap());
    return SaveRecordResult.inserted;
  }

  @override
  Future<SaveRecordResult> saveValidatedRecord(MedicationRecord record) async {
    final result = await _db.transaction((txn) => _save(txn, record));
    if (result == SaveRecordResult.inserted) _changes.add(null);
    return result;
  }

  @override
  Future<List<MedicationRecord>> readAll() async => (await _db.query('records',
          orderBy: 'timestamp DESC, device_id, seq DESC'))
      .map(MedicationRecord.fromMap)
      .toList(growable: false);

  @override
  Future<DateTime?> lastSyncAt() async {
    final rows = await _db
        .query('metadata', where: 'key = ?', whereArgs: ['last_sync_at']);
    return rows.isEmpty ? null : DateTime.parse(rows.single['value'] as String);
  }

  @override
  Future<void> markSyncCompleted(DateTime instant) async {
    await _db.insert('metadata', {
      'key': 'last_sync_at',
      'value': instant.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.add(null);
  }

  @override
  Future<int?> readSyncCursor(String deviceId) async {
    final rows = await _db
        .query('sync_cursors', where: 'device_id = ?', whereArgs: [deviceId]);
    return rows.isEmpty ? null : rows.single['seq'] as int;
  }

  @override
  Future<void> advanceSyncCursor(
    String deviceId,
    int seq, {
    int? firstSequence,
  }) async {
    if (deviceId.trim().isEmpty || seq < 0 || seq > 0xffffffff) {
      throw ArgumentError('Invalid device sync cursor');
    }
    await _db.transaction((txn) async {
      final old = await txn
          .query('sync_cursors', where: 'device_id = ?', whereArgs: [deviceId]);
      final previous = old.isEmpty ? null : old.single['seq'] as int;
      if (previous != null && seq < previous) {
        throw StateError('Cursor cannot move backwards');
      }
      if (previous == null &&
          (firstSequence == null || firstSequence < 0 || firstSequence > seq)) {
        throw StateError(
            'First advance requires the device/session first sequence');
      }
      // The first sequence must come from the frozen protocol/session identity,
      // never MIN/MAX of the packets that happened to arrive at the phone.
      final start = previous ?? firstSequence!;
      final saved = await txn.query('records',
          columns: ['seq'],
          where: 'device_id = ? AND seq >= ? AND seq <= ?',
          whereArgs: [deviceId, start, seq],
          orderBy: 'seq');
      final expected = seq - start + 1;
      if (saved.length != expected) {
        throw StateError('Cannot advance across missing records');
      }
      await txn.insert('sync_cursors', {'device_id': deviceId, 'seq': seq},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> close() async {
    await _db.close();
    await _changes.close();
  }
}
