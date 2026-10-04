import 'package:medication_device_app/database/record_repository.dart';
import 'package:medication_device_app/models/medication_record.dart';

/// Test-only records, never bundled into the App's production entrypoint.
Future<void> saveTestDeviceRecords(
  RecordRepository repository,
  DateTime now,
) async {
  final local = now.toLocal();
  final start = DateTime(local.year, local.month, local.day);
  for (var i = 0; i < 10; i++) {
    final dayOffset = i ~/ 2;
    final time = dayOffset == 0
        ? start.add(
            Duration(minutes: i == 0 ? 0 : local.hour * 60 + local.minute),
          )
        : DateTime(
            start.year,
            start.month,
            start.day - dayOffset,
            8 + i % 2 * 10,
            20,
          );
    await repository.saveValidatedRecord(
      MedicationRecord(
        deviceId: 'fixture-device',
        seq: i + 1,
        timestamp: time.millisecondsSinceEpoch ~/ 1000,
        eventType: i == 3 ? 2 : (i == 7 ? 3 : 1),
        durationMs: 1100 + i * 20,
        pressurePeakPa: -84 + i,
        confidence: i == 3 ? 40 : 92,
        batteryMv: 3800 - i * 10,
      ),
    );
  }
  await repository.saveValidatedRecord(
    MedicationRecord(
      deviceId: 'fixture-device',
      seq: 11,
      timestamp: 0,
      eventType: 1,
      durationMs: 1200,
      pressurePeakPa: -82,
      confidence: 88,
      batteryMv: 3700,
    ),
  );
}
