import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/medication_record.dart';
import '../ble/prototype_protocol.dart';
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
    final dbPath =
        path ??
        p.join(await dbFactory.getDatabasesPath(), 'records_${source.name}.db');
    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
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
            'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE sync_cursors (device_id TEXT PRIMARY KEY, seq INTEGER NOT NULL)',
          );
          await db.insert('metadata', {'key': 'source', 'value': source.name});
          await _createTimestampTable(db);
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) await _createTimestampTable(db);
        },
      ),
    );
    final dataset = await db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['source'],
    );
    if (dataset.single['value'] != source.name) {
      await db.close();
      throw StateError('Database dataset does not match ${source.name}');
    }
    return SqliteRecordRepository._(db, source);
  }

  @override
  Stream<void> get changes => _changes.stream;

  static Future<void> _createTimestampTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE timestamp_uses (
      device_id TEXT NOT NULL, file_id TEXT NOT NULL,
      raw_text TEXT NOT NULL, received_at TEXT NOT NULL,
      PRIMARY KEY(device_id, file_id))''');
    await db.execute(
      'CREATE INDEX timestamp_uses_time ON timestamp_uses(raw_text)',
    );
  }

  /// One unique hardware file = one diary entry. Replays repair an interrupted
  /// projection but cannot add a second use or replace an existing payload.
  Future<void> saveDeviceTimestamp(PrototypeRecord record) async {
    final inserted = await _db.transaction((txn) async {
      final old = await txn.query(
        'timestamp_uses',
        where: 'device_id = ? AND file_id = ?',
        whereArgs: [record.deviceId, record.fileId],
      );
      if (old.isNotEmpty) {
        if (old.single['raw_text'] != record.rawText) {
          throw StateError(
            'Device file content changed; synchronization stopped.',
          );
        }
        return false;
      }
      await txn.insert('timestamp_uses', {
        'device_id': record.deviceId,
        'file_id': record.fileId,
        'raw_text': record.rawText,
        'received_at': record.receivedAt.toUtc().toIso8601String(),
      });
      return true;
    });
    if (inserted) _changes.add(null);
  }

  Future<SaveRecordResult> _save(
    Transaction txn,
    MedicationRecord record,
  ) async {
    final previous = await txn.query(
      'records',
      where: 'device_id = ? AND seq = ?',
      whereArgs: [record.deviceId, record.seq],
    );
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
    if (record.isTimestampRecord) {
      throw ArgumentError(
        'Use saveDeviceTimestamp for timestamp diary entries',
      );
    }
    final result = await _db.transaction((txn) => _save(txn, record));
    if (result == SaveRecordResult.inserted) _changes.add(null);
    return result;
  }

  @override
  Future<List<MedicationRecord>> readAll() async {
    final structured = (await _db.query(
      'records',
      orderBy: 'timestamp DESC, device_id, seq DESC',
    )).map(MedicationRecord.fromMap).toList(growable: false);
    final timestamps = (await _db.query('timestamp_uses')).map(
      (row) => MedicationRecord.deviceTimestamp(
        deviceId: row['device_id'] as String,
        fileId: row['file_id'] as String,
        rawText: row['raw_text'] as String,
        receivedAt: DateTime.parse(row['received_at'] as String),
      ),
    );
    final records = [...structured, ...timestamps];
    records.sort((a, b) {
      final left = a.localOccurredAt;
      final right = b.localOccurredAt;
      if (left != null && right != null) {
        final order = _calendarKey(right).compareTo(_calendarKey(left));
        if (order != 0) return order;
      } else if (left != null) {
        return -1;
      } else if (right != null) {
        return 1;
      }
      return '${a.deviceId}/${a.deviceFileId ?? a.seq}'.compareTo(
        '${b.deviceId}/${b.deviceFileId ?? b.seq}',
      );
    });
    return records;
  }

  static int _calendarKey(DateTime date) => DateTime.utc(
    date.year,
    date.month,
    date.day,
    date.hour,
    date.minute,
    date.second,
  ).millisecondsSinceEpoch;

  @override
  Future<DateTime?> lastSyncAt() async {
    final rows = await _db.query(
      'metadata',
      where: 'key = ?',
      whereArgs: ['last_sync_at'],
    );
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
    final rows = await _db.query(
      'sync_cursors',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
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
      final old = await txn.query(
        'sync_cursors',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      final previous = old.isEmpty ? null : old.single['seq'] as int;
      if (previous != null && seq < previous) {
        throw StateError('Cursor cannot move backwards');
      }
      if (previous == null &&
          (firstSequence == null || firstSequence < 0 || firstSequence > seq)) {
        throw StateError(
          'First advance requires the device/session first sequence',
        );
      }
      // The first sequence must come from the frozen protocol/session identity,
      // never MIN/MAX of the packets that happened to arrive at the phone.
      final start = previous ?? firstSequence!;
      final saved = await txn.query(
        'records',
        columns: ['seq'],
        where: 'device_id = ? AND seq >= ? AND seq <= ?',
        whereArgs: [deviceId, start, seq],
        orderBy: 'seq',
      );
      final expected = seq - start + 1;
      if (saved.length != expected) {
        throw StateError('Cannot advance across missing records');
      }
      await txn.insert('sync_cursors', {
        'device_id': deviceId,
        'seq': seq,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> close() async {
    await _db.close();
    await _changes.close();
  }
}
