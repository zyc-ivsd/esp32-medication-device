import '../assistant/models/assistant_context.dart';
import 'medication_record.dart';

class DailyCount {
  const DailyCount(this.day, this.count);
  final DateTime day;
  final int count;
}

class RecordSummary {
  const RecordSummary({
    required this.total,
    required this.todayCount,
    required this.last7DaysCount,
    required this.invalidEventCount,
    required this.unknownTimeCount,
    required this.futureTimeCount,
    required this.days,
    this.lastSyncAt,
  });

  final int total;
  final int todayCount;
  final int last7DaysCount;

  /// Suspected invalid events during the same seven local calendar days.
  final int invalidEventCount;
  final int unknownTimeCount;
  final int futureTimeCount;
  final List<DailyCount> days;
  final DateTime? lastSyncAt;

  factory RecordSummary.calculate(
    Iterable<MedicationRecord> records, {
    required DateTime now,
    DateTime? lastSyncAt,
  }) {
    final localNow = now.toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    final start = DateTime(today.year, today.month, today.day - 6);
    final days = List.generate(
      7,
      (index) => DateTime(start.year, start.month, start.day + index),
    );
    final counts = List.filled(7, 0);
    var total = 0;
    var invalid = 0;
    var unknown = 0;
    var future = 0;
    for (final record in records) {
      total++;
      final eventTime = record.occurredAt?.toLocal();
      if (eventTime == null) {
        unknown++;
        continue;
      }
      if (eventTime.isAfter(localNow)) {
        future++;
        continue;
      }
      if (eventTime.isBefore(start)) continue;
      if (record.eventType == 2) invalid++;
      if (record.eventType != 1) continue;
      // Calendar comparison avoids 23/25-hour DST day rounding errors.
      final index = days.indexWhere((day) =>
          day.year == eventTime.year &&
          day.month == eventTime.month &&
          day.day == eventTime.day);
      if (index >= 0) counts[index]++;
    }
    return RecordSummary(
      total: total,
      todayCount: counts.last,
      last7DaysCount: counts.fold(0, (sum, count) => sum + count),
      invalidEventCount: invalid,
      unknownTimeCount: unknown,
      futureTimeCount: future,
      days: List.unmodifiable([
        for (var i = 0; i < 7; i++) DailyCount(days[i], counts[i]),
      ]),
      lastSyncAt: lastSyncAt,
    );
  }

  AssistantContext toAssistantContext(RecordSource source) => AssistantContext(
        todayCount: todayCount,
        last7DaysCount: last7DaysCount,
        invalidEventCount: invalidEventCount,
        lastSyncAt: lastSyncAt,
        isDemo: source == RecordSource.demo,
        unknownTimeCount: unknownTimeCount,
        futureTimeCount: futureTimeCount,
        totalCount: total,
        // 与 last7DaysCount 同源，两者之和必须一致，网关也会校验。
        dailyCounts: [for (final day in days) day.count],
      );
}
