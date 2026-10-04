import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'prototype_protocol.dart';

/// Kept separate from the device event store: a button timestamp has no event
/// type, pressure or confidence and cannot be turned into a medication event.
abstract interface class PrototypeStore {
  Future<void> save(PrototypeRecord record);
  Future<List<PrototypeRecord>> readRecent();
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
          throw StateError('同一设备文件的内容改变，已停止确认，请检查固件是否覆盖文件');
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
  Future<void> close() => _db.close();
}
