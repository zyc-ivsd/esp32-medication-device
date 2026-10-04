enum RecordSource {
  device('Device records');

  const RecordSource(this.label);
  final String label;
}

/// A saved device event or a button-triggered timestamp diary entry.
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
    this.deviceFileId,
    this.rawTimestampText,
    this.receivedAt,
  }) {
    if (deviceId.trim().isEmpty || deviceId.length > 128) {
      throw ArgumentError.value(deviceId, 'deviceId');
    }
    _range(seq, 0, 0xffffffff, 'seq');
    _range(timestamp, 0, 0xffffffff, 'timestamp');
    _range(eventType, 1, 3, 'eventType');
    if (!isTimestampRecord) {
      _range(durationMs!, 0, 0xffff, 'durationMs');
      _range(pressurePeakPa!, -32768, 32767, 'pressurePeakPa');
      _range(confidence!, 0, 100, 'confidence');
      _range(batteryMv!, 0, 0xffff, 'batteryMv');
    } else if (timestamp != 0 ||
        durationMs != null ||
        pressurePeakPa != null ||
        confidence != null ||
        batteryMv != null ||
        rawTimestampText == null ||
        receivedAt == null) {
      throw ArgumentError(
        'Timestamp records cannot contain invented measurements',
      );
    }
    if (protocolVersion != 1) {
      throw ArgumentError.value(protocolVersion, 'protocolVersion');
    }
  }

  final String deviceId;
  final int seq;
  final int timestamp;
  final int eventType;
  final int? durationMs;
  final int? pressurePeakPa;
  final int? confidence;
  final int? batteryMv;
  final int protocolVersion;
  final String? algorithmVersion;
  final String? deviceFileId;
  final String? rawTimestampText;
  final DateTime? receivedAt;

  factory MedicationRecord.deviceTimestamp({
    required String deviceId,
    required String fileId,
    required String rawText,
    required DateTime receivedAt,
  }) => MedicationRecord(
    deviceId: deviceId,
    seq: 0,
    timestamp: 0,
    eventType: 1,
    durationMs: null,
    pressurePeakPa: null,
    confidence: null,
    batteryMv: null,
    deviceFileId: fileId,
    rawTimestampText: rawText,
    receivedAt: receivedAt,
  );

  bool get isTimestampRecord => deviceFileId != null;
  bool get hasUnixTime => timestamp != 0;
  // Device records carry a UTC instant (hex Unix seconds). Convert to the
  // phone's current timezone for display; changing the phone timezone only
  // changes the presentation, not the stored instant.
  DateTime? get localOccurredAt => isTimestampRecord
      ? parseDeviceTimestamp(rawTimestampText!)?.toLocal()
      : occurredAt?.toLocal();

  bool get hasKnownTime => localOccurredAt != null;
  DateTime? get occurredAt => hasUnixTime
      ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true)
      : null;
  String get eventLabel => isTimestampRecord && !hasKnownTime
      ? 'Device timestamp · check time'
      : switch (eventType) {
          1 => 'Medication use',
          2 => 'Suspected invalid use',
          _ => 'Other event',
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
    if (isTimestampRecord) ...{
      'device_file_id': deviceFileId,
      'raw_timestamp_text': rawTimestampText,
      'received_at': receivedAt!.toUtc().toIso8601String(),
    },
  };

  factory MedicationRecord.fromMap(Map<String, Object?> row) =>
      row['device_file_id'] != null
      ? MedicationRecord.deviceTimestamp(
          deviceId: row['device_id'] as String,
          fileId: row['device_file_id'] as String,
          rawText: row['raw_timestamp_text'] as String,
          receivedAt: DateTime.parse(row['received_at'] as String),
        )
      : MedicationRecord(
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

/// Parses the device's raw record: 16 lowercase/uppercase hex digits holding
/// UTC Unix seconds. Returns the UTC instant, or null when the value is
/// malformed, out of the supported 2001–2099 range, or the firmware's year-2000
/// placeholder. Callers apply the phone's current timezone offset for display.
DateTime? parseDeviceTimestamp(String text) {
  if (!RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(text)) return null;
  final seconds = int.tryParse(text, radix: 16);
  if (seconds == null || seconds < 978307200 || seconds > 4102444799) {
    // 978307200 = 2001-01-01T00:00:00Z; 4102444799 = 2099-12-31T23:59:59Z.
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
