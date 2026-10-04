import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/medication_record.dart';

class CsvExportService {
  /// Receives the same filtered snapshot as the history list. Every event,
  /// including unknown time and invalid events, keeps its original fields.
  static String encode(
    Iterable<MedicationRecord> records,
    RecordSource source,
  ) {
    const header = [
      'source',
      'device_id',
      'seq',
      'timestamp_unix_seconds',
      'occurred_at_utc',
      'occurred_at_local',
      'time_status',
      'event_type',
      'duration_ms',
      'pressure_peak_pa',
      'confidence',
      'battery_mv',
      'protocol_version',
      'algorithm_version',
      'record_kind',
      'device_file_id',
      'raw_timestamp_text',
      'time_basis',
      'received_at_utc',
    ];
    final rows = <List<Object?>>[
      header,
      for (final record in records)
        [
          source.name,
          _safeText(record.deviceId),
          record.isTimestampRecord ? '' : record.seq,
          record.isTimestampRecord
              ? (record.hasKnownTime
                    ? (int.parse(record.rawTimestampText!, radix: 16))
                    : '')
              : record.timestamp,
          record.isTimestampRecord
              ? (parseDeviceTimestamp(record.rawTimestampText!)?.toIso8601String() ??
                    '')
              : record.occurredAt?.toIso8601String() ?? '',
          record.localOccurredAt?.toIso8601String() ?? '',
          record.hasKnownTime ? 'known' : 'unknown',
          record.eventType,
          record.durationMs,
          record.pressurePeakPa,
          record.confidence,
          record.batteryMv,
          record.isTimestampRecord ? 'P01' : record.protocolVersion,
          _safeText(record.algorithmVersion ?? ''),
          record.isTimestampRecord ? 'button_timestamp' : 'structured_event',
          _safeText(record.deviceFileId ?? ''),
          _safeText(record.rawTimestampText ?? ''),
          // Both record kinds now carry Unix UTC seconds.
          'unix_utc',
          record.receivedAt?.toUtc().toIso8601String() ?? '',
        ],
    ];
    return '\uFEFF${rows.map((row) => row.map(_cell).join(',')).join('\r\n')}\r\n';
  }

  static String _cell(Object? value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';
  static String _safeText(String value) =>
      RegExp(r'^\s*[=+@\-\t\r\n]').hasMatch(value) ? "'$value" : value;

  Future<void> share({
    required List<MedicationRecord> records,
    required RecordSource source,
    required Rect origin,
  }) async {
    if (records.isEmpty) throw StateError('No records to export');
    final directory = await getTemporaryDirectory();
    final name =
        'records_${source.name}_${DateTime.now().microsecondsSinceEpoch}.csv';
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(utf8.encode(encode(records, source)), flush: true);
    // Keep the temporary file after handoff: a recipient can read it lazily.
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: '${source.label} export',
      sharePositionOrigin: origin,
    );
  }
}
