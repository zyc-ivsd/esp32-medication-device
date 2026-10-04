import 'prototype_protocol.dart';
import 'prototype_store.dart';

/// Transport-independent, serialized by BleService. Writes ACK only after the
/// SQLite transaction finishes. A reconnect uses a new token and resends files.
class PrototypeSync {
  PrototypeSync({
    required this.deviceId,
    required this.token,
    required this.store,
    required this.write,
    required this.isActive,
  });
  final String deviceId;
  final String token;
  final PrototypeStore store;
  final Future<void> Function(String command) write;
  final bool Function() isActive;
  int? expectedCount;
  final Map<int, String> _saved = {};
  final Set<String> _fileIds = {};
  bool endReceived = false;
  bool completed = false;
  int get savedCount => _saved.length;

  Future<void> accept(List<String> fields) async {
    if (!isActive() || fields.length < 2 || fields[1] != token) return;
    switch (fields[0]) {
      case 'BEGIN':
        if (fields.length != 3) {
          throw const FormatException('Invalid BEGIN frame');
        }
        final count = int.parse(fields[2]);
        if (count < 0 ||
            count > 256 ||
            (expectedCount != null && expectedCount != count)) {
          throw const FormatException(
            'Record count mismatch or prototype limit exceeded',
          );
        }
        expectedCount = count;
        await write('START|$token');
      case 'R':
        if (fields.length != 5 || expectedCount == null || completed) {
          throw const FormatException('Record before BEGIN or invalid format');
        }
        final index = int.parse(fields[2]);
        final file = fields[3];
        final raw = fields[4];
        if (index < 0 ||
            index >= expectedCount! ||
            index > _saved.length ||
            !RegExp(r'^data_[A-Za-z0-9_.-]{1,80}\.txt$').hasMatch(file) ||
            !RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(raw)) {
          throw const FormatException(
            'Invalid record index, file name or UTC-hex timestamp format',
          );
        }
        final payload = '$file|$raw';
        if ((_saved.containsKey(index) && _saved[index] != payload) ||
            (!_saved.containsKey(index) && _fileIds.contains(file))) {
          throw const FormatException(
            'Conflicting retransmission or duplicate file',
          );
        }
        await store.save(
          PrototypeRecord(
            deviceId: deviceId,
            fileId: file,
            rawText: raw,
            receivedAt: DateTime.now(),
          ),
        );
        if (!isActive()) return;
        _saved[index] = payload;
        _fileIds.add(file);
        await write('ACK|$token|$index');
      case 'END':
        if (fields.length != 3 ||
            expectedCount == null ||
            int.parse(fields[2]) != expectedCount ||
            _saved.length != expectedCount) {
          throw const FormatException(
            'Records have not all been saved; COMMIT not sent',
          );
        }
        endReceived = true;
        await write('COMMIT|$token');
      case 'DONE':
        if (fields.length != 2 || !endReceived) {
          throw const FormatException(
            'DONE received before all records were saved',
          );
        }
        completed = true;
      case 'ERROR':
        throw StateError('Device sync error: ${fields.skip(2).join(' ')}');
      default:
        throw const FormatException('Unknown prototype frame type');
    }
  }
}
