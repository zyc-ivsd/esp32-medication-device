class AssistantContext {
  const AssistantContext({
    this.todayCount = 0,
    this.last7DaysCount = 0,
    this.invalidEventCount = 0,
    this.lastSyncAt,
  });

  final int todayCount;
  final int last7DaysCount;
  final int invalidEventCount;
  final DateTime? lastSyncAt;

  Map<String, dynamic> toJson() {
    return {
      'today_count': todayCount,
      'last_7_days_count': last7DaysCount,
      'invalid_event_count': invalidEventCount,
      'last_sync_at': lastSyncAt?.toUtc().toIso8601String(),
    };
  }

  String toPromptSummary() {
    final syncText = lastSyncAt == null
        ? '尚未同步'
        : '最后同步于 ${lastSyncAt!.toLocal()}';
    return '今天 $todayCount 次，近 7 天 $last7DaysCount 次，'
        '疑似无效记录 $invalidEventCount 条，$syncText。';
  }
}
