import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'prototype_protocol.dart';

/// Raw wire evidence is retained independently of the medication diary.
abstract interface class PrototypeStore {
  Future<void> save(PrototypeRecord record);
  Future<List<PrototypeRecord>> readRecent();
  Future<List<PrototypeRecord>> readAll();
  Future<void> close();
}

class SqlitePrototypeStore implements PrototypeStore {
  SqlitePrototypeStore._(this._db);
  final Database _db;

  static Future<SqlitePrototypeStore> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final db = await dbFactory.openDatabase(
      path ?? p.join(await dbFactory.getDatabasesPath(), 'prototype_text.db'),
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onConfigure: (db) => db.execute('PRAGMA synchronous = FULL'),
        onCreate: (db, _) => db.execute('''CREATE TABLE prototype_text (
          device_id TEXT NOT NULL, file_id TEXT NOT NULL,
          raw_text TEXT NOT NULL, received_at TEXT NOT NULL,
          PRIMARY KEY(device_id, file_id))'''),
      ),
    );
    return SqlitePrototypeStore._(db);
  }

  @override
  Future<void> save(PrototypeRecord record) async {
    await _db.transaction((txn) async {
      final previous = await txn.query(
        'prototype_text',
        where: 'device_id = ? AND file_id = ?',
        whereArgs: [record.deviceId, record.fileId],
      );
      if (previous.isNotEmpty) {
        if (previous.single['raw_text'] != record.rawText) {
          throw StateError(
            'Device file content changed. Check whether the firmware overwrote a file.',
          );
        }
        return;
      }
      await txn.insert('prototype_text', {
        'device_id': record.deviceId,
        'file_id': record.fileId,
        'raw_text': record.rawText,
        'received_at': record.receivedAt.toUtc().toIso8601String(),
      });
    });
  }

  @override
  Future<List<PrototypeRecord>> readRecent() async =>
      (await _db.query(
            'prototype_text',
            orderBy: 'received_at DESC, file_id DESC',
            limit: 100,
          ))
          .map(
            (row) => PrototypeRecord(
              deviceId: row['device_id'] as String,
              fileId: row['file_id'] as String,
              rawText: row['raw_text'] as String,
              receivedAt: DateTime.parse(row['received_at'] as String),
            ),
          )
          .toList();

  @override
  Future<List<PrototypeRecord>> readAll() async =>
      (await _db.query('prototype_text', orderBy: 'received_at, file_id'))
          .map(
            (row) => PrototypeRecord(
              deviceId: row['device_id'] as String,
              fileId: row['file_id'] as String,
              rawText: row['raw_text'] as String,
              receivedAt: DateTime.parse(row['received_at'] as String),
            ),
          )
          .toList();

  @override
  Future<void> close() => _db.close();
}

/// ACK is sent by PrototypeSync only after both durable writes succeed. If a
/// process stops between them, replay/backfill completes the projection safely.
class RecordingPrototypeStore implements PrototypeStore {
  RecordingPrototypeStore(this.rawStore, this.recordUse);
  final PrototypeStore rawStore;
  final Future<void> Function(PrototypeRecord) recordUse;

  @override
  Future<void> save(PrototypeRecord record) async {
    await rawStore.save(record);
    await recordUse(record);
  }

  Future<void> backfill() async {
    for (final record in await rawStore.readAll()) {
      await recordUse(record);
    }
  }

  @override
  Future<List<PrototypeRecord>> readRecent() => rawStore.readRecent();
  @override
  Future<List<PrototypeRecord>> readAll() => rawStore.readAll();
  @override
  Future<void> close() => rawStore.close();
}
