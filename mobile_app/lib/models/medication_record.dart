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
  // The wire text carries a wall-clock time, not a UTC offset. Preserve its
  // calendar fields instead of inventing a UTC instant using today's offset.
  // For timestamp entries a UTC DateTime carries calendar components only:
  // callers must not convert it to another timezone or export it as an instant.
  DateTime? get localOccurredAt => isTimestampRecord
      ? parseDeviceTimestamp(rawTimestampText!)
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

/// Strict calendar validation: DateTime.parse/constructors normalize invalid
/// dates such as February 31. The firmware's 2000 clock placeholder is excluded.
DateTime? parseDeviceTimestamp(String text) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$',
  ).firstMatch(text);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  final [year, month, day, hour, minute, second] = parts;
  if (year <= 2000 ||
      year > 2099 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  // Validate in UTC so DST gaps in the phone's timezone cannot normalize a
  // device's calendar date. This is a calendar carrier, not a UTC instant.
  final checked = DateTime.utc(year, month, day, hour, minute, second);
  if (checked.year != year || checked.month != month || checked.day != day) {
    return null;
  }
  return checked;
}
