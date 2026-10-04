enum RecordSource {
  device('设备记录');

  const RecordSource(this.label);
  final String label;
}

/// A decoded, CRC-validated protocol record. Wire validation belongs to BLE.
/// A detected event is not proof of ingestion or a measured medication dose.
class MedicationRecord {
  MedicationRecord({
    required this.deviceId,
    required this.seq,
    required this.timestamp,
    required this.eventType,
    required this.durationMs,
    required this.pressurePeakPa,
    required this.confidence,
    required this.batteryMv,
    this.protocolVersion = 1,
    this.algorithmVersion,
  }) {
    if (deviceId.trim().isEmpty || deviceId.length > 128) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
    _range(seq, 0, 0xffffffff, 'seq');
    _range(timestamp, 0, 0xffffffff, 'timestamp');
    _range(eventType, 1, 3, 'eventType');
    _range(durationMs, 0, 0xffff, 'durationMs');
    _range(pressurePeakPa, -32768, 32767, 'pressurePeakPa');
    _range(confidence, 0, 100, 'confidence');
    _range(batteryMv, 0, 0xffff, 'batteryMv');
    if (protocolVersion != 1) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
  }

  final String deviceId;
  final int seq;
  final int timestamp;
  final int eventType;
  final int durationMs;
  final int pressurePeakPa;
  final int confidence;
  final int batteryMv;
  final int protocolVersion;
  final String? algorithmVersion;

  bool get hasKnownTime => timestamp != 0;
  DateTime? get occurredAt => hasKnownTime
      ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true)
      : null;
  String get eventLabel => switch (eventType) {
        1 => '使用动作',
        2 => '疑似无效',
        _ => '其他事件',
      };

  Map<String, Object?> toMap() => {
        'device_id': deviceId,
        'seq': seq,
        'timestamp': timestamp,
        'event_type': eventType,
        'duration_ms': durationMs,
        'pressure_peak_pa': pressurePeakPa,
        'confidence': confidence,
        'battery_mv': batteryMv,
        'protocol_version': protocolVersion,
        'algorithm_version': algorithmVersion,
      };

  factory MedicationRecord.fromMap(Map<String, Object?> row) =>
      MedicationRecord(
        deviceId: row['device_id'] as String,
        seq: row['seq'] as int,
        timestamp: row['timestamp'] as int,
        eventType: row['event_type'] as int,
        durationMs: row['duration_ms'] as int,
        pressurePeakPa: row['pressure_peak_pa'] as int,
        confidence: row['confidence'] as int,
        batteryMv: row['battery_mv'] as int,
        protocolVersion: row['protocol_version'] as int? ?? 1,
        algorithmVersion: row['algorithm_version'] as String?,
      );

  bool samePayload(MedicationRecord other) {
    final values = other.toMap();
    return toMap().entries.every((entry) => values[entry.key] == entry.value);
  }

  static void _range(int value, int min, int max, String name) {
    if (value < min || value > max) {
      throw RangeError.range(value, min, max, name);
    }
  }
}
