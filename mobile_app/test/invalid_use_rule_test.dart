import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/models/invalid_use_rule.dart';
import 'package:medication_device_app/models/medication_record.dart';

MedicationRecord button(
  DateTime local, {
  String file = '1.txt',
  String device = 'C3-A',
}) => MedicationRecord.deviceTimestamp(
  deviceId: device,
  fileId: file,
  rawText: (local.toUtc().millisecondsSinceEpoch ~/ 1000)
      .toRadixString(16)
      .padLeft(16, '0'),
  receivedAt: local,
);

void main() {
  test('same-second presses mark the earlier record as invalid', () {
    final records = applySuspectedInvalidUseRule([
      button(DateTime(2026, 10, 4, 8), file: '2.txt'),
      button(DateTime(2026, 10, 4, 8), file: '1.txt'),
    ]);
    final byFile = {for (final record in records) record.deviceFileId!: record};
    expect(byFile['1.txt']!.eventType, 2);
    expect(byFile['2.txt']!.eventType, 1);
  });

  test('a one-second gap invalidates the earlier record', () {
    final records = applySuspectedInvalidUseRule([
      button(DateTime(2026, 10, 4, 8, 0, 0), file: '1.txt'),
      button(DateTime(2026, 10, 4, 8, 0, 1), file: '2.txt'),
    ]);
    expect(records[0].eventType, 2);
    expect(records[1].eventType, 1);
  });

  test('a two-second gap keeps both records valid', () {
    final records = applySuspectedInvalidUseRule([
      button(DateTime(2026, 10, 4, 8, 0, 0), file: '1.txt'),
      button(DateTime(2026, 10, 4, 8, 0, 2), file: '2.txt'),
    ]);
    expect(records.map((record) => record.eventType), [1, 1]);
  });

  test('records from different devices are compared separately', () {
    final records = applySuspectedInvalidUseRule([
      button(DateTime(2026, 10, 4, 8), file: '1.txt', device: 'C3-A'),
      button(DateTime(2026, 10, 4, 8), file: '1.txt', device: 'C3-B'),
    ]);
    expect(records.map((record) => record.eventType), [1, 1]);
  });

  test('other events and unknown times are never reclassified', () {
    final unknown = MedicationRecord(
      deviceId: 'C3-A',
      seq: 1,
      timestamp: 0,
      eventType: 1,
      durationMs: 1200,
      pressurePeakPa: -84,
      confidence: 90,
      batteryMv: 3700,
    );
    final other = MedicationRecord(
      deviceId: 'C3-A',
      seq: 2,
      timestamp: DateTime(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000,
      eventType: 3,
      durationMs: 900,
      pressurePeakPa: -60,
      confidence: 80,
      batteryMv: 3700,
    );
    final use = MedicationRecord(
      deviceId: 'C3-A',
      seq: 3,
      timestamp: DateTime(2026, 10, 4, 8, 0, 1).millisecondsSinceEpoch ~/ 1000,
      eventType: 1,
      durationMs: 900,
      pressurePeakPa: -60,
      confidence: 80,
      batteryMv: 3700,
    );
    final records = applySuspectedInvalidUseRule([unknown, other, use]);
    expect(records[0].eventType, 1);
    expect(records[1].eventType, 3);
    expect(records[2].eventType, 1);
  });

  test('applying the rule twice gives the same result', () {
    final first = applySuspectedInvalidUseRule([
      button(DateTime(2026, 10, 4, 8), file: '1.txt'),
      button(DateTime(2026, 10, 4, 8), file: '2.txt'),
      button(DateTime(2026, 10, 4, 9), file: '3.txt'),
    ]);
    final second = applySuspectedInvalidUseRule(first);
    expect(
      second.map((record) => record.eventType),
      first.map((record) => record.eventType),
    );
  });
}
