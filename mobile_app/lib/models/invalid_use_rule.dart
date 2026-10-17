import 'medication_record.dart';

/// Two records from the same device that are at most one second apart are
/// treated as one medication use: the earlier record is marked as a suspected
/// invalid use (event type 2). It stays visible for review but no longer counts
/// as a medication use.
///
/// Device records store whole Unix seconds, so a gap of 0 or 1 second covers
/// two presses inside the same second as well as adjacent seconds. Records
/// without a known time and explicit "other events" (type 3) are ignored by the
/// pairing and never reclassified. The rule is idempotent, so it can be
/// re-applied whenever the dataset is reloaded.
List<MedicationRecord> applySuspectedInvalidUseRule(
  Iterable<MedicationRecord> records,
) {
  final result = List<MedicationRecord>.of(records);
  final indexesByDevice = <String, List<int>>{};
  for (var i = 0; i < result.length; i++) {
    if (result[i].eventType == 3) continue;
    if (result[i].localOccurredAt != null) {
      indexesByDevice.putIfAbsent(result[i].deviceId, () => <int>[]).add(i);
    }
  }
  for (final indexes in indexesByDevice.values) {
    indexes.sort((a, b) {
      final time = result[a].localOccurredAt!.compareTo(
        result[b].localOccurredAt!,
      );
      if (time != 0) return time;
      // Same second: keep "the earlier record" stable across reloads.
      return _identityKey(result[a]).compareTo(_identityKey(result[b]));
    });
    for (var i = 0; i + 1 < indexes.length; i++) {
      final earlier = result[indexes[i]];
      final later = result[indexes[i + 1]];
      final gap = later.localOccurredAt!.difference(earlier.localOccurredAt!);
      if (gap.inMilliseconds > 1000) continue;
      if (earlier.eventType == 1) {
        result[indexes[i]] = earlier.copyWith(eventType: 2);
      }
    }
  }
  return List.unmodifiable(result);
}

String _identityKey(MedicationRecord record) =>
    '${record.deviceFileId ?? ''}/${record.seq.toString().padLeft(10, '0')}';
