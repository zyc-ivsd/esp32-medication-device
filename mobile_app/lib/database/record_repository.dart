import '../models/medication_record.dart';

enum SaveRecordResult { inserted, duplicate }

class RecordConflictException implements Exception {
  const RecordConflictException(this.deviceId, this.seq);
  final String deviceId;
  final int seq;
  @override
  String toString() =>
      'Conflicting payload for device sequence: $deviceId / $seq';
}

/// B calls saveValidatedRecord AFTER length/version/CRC validation.
/// Only a successful future (inserted or identical duplicate) permits ACK.
/// Exceptions must not be acknowledged. This interface does not send ACK/COMMIT.
abstract class RecordRepository {
  RecordSource get source;
  Stream<void> get changes;
  Future<SaveRecordResult> saveValidatedRecord(MedicationRecord record);
  Future<List<MedicationRecord>> readAll();
  Future<DateTime?> lastSyncAt();
  Future<void> markSyncCompleted(DateTime instant);

  /// Persisted separately from the greatest observed sequence. B advances this
  /// only after verifying a continuous saved range and the device's SYNC_END.
  Future<int?> readSyncCursor(String deviceId);
  Future<void> advanceSyncCursor(
    String deviceId,
    int seq, {
    int? firstSequence,
  });

  Future<void> close();
}
