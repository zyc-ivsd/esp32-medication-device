/// Local calendar dates, with an exclusive end. Unknown timestamps are never
/// assigned to a day; they can be included explicitly alongside a date range.
class RecordFilter {
  const RecordFilter({
    this.start,
    this.endExclusive,
    this.includeUnknown = true,
  });

  final DateTime? start;
  final DateTime? endExclusive;
  final bool includeUnknown;

  bool accepts(int timestamp) {
    if (timestamp == 0) return includeUnknown;
    final instant = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return acceptsLocalTime(instant);
  }

  bool acceptsLocalTime(DateTime? time) {
    if (time == null) return includeUnknown;
    final day = DateTime.utc(time.year, time.month, time.day);
    DateTime calendar(DateTime date) =>
        DateTime.utc(date.year, date.month, date.day);
    return (start == null || !day.isBefore(calendar(start!))) &&
        (endExclusive == null || day.isBefore(calendar(endExclusive!)));
  }

  String get description {
    if (start == null && endExclusive == null) return 'All dates';
    final end = endExclusive;
    final lastDay = end == null
        ? null
        : DateTime(end.year, end.month, end.day - 1);
    return '${start == null ? 'Any' : dateLabel(start!)} to '
        '${lastDay == null ? 'Any' : dateLabel(lastDay)}';
  }
}

String dateLabel(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String timeLabel(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:'
    '${date.minute.toString().padLeft(2, '0')}';
