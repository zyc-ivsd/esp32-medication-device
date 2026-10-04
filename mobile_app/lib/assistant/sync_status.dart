import 'models/assistant_context.dart';
import 'rules/observation_rules.dart';

/// 同步状态的分类：助手卡上的一枚小徽章，一眼看出数据新不新。
enum SyncStatus { never, stale, fresh }

/// 按设备数据的同步时间分类。
SyncStatus syncStatus(AssistantContext context, DateTime now) {
  final lastSync = context.lastSyncAt;
  if (lastSync == null) return SyncStatus.never;
  final localNow = now.toLocal();
  final lastLocal = lastSync.toLocal();
  // 与规则层同口径：按日历天比较，避免夏令时 23/25 小时取整误差。
  final days = DateTime(localNow.year, localNow.month, localNow.day)
      .difference(DateTime(lastLocal.year, lastLocal.month, lastLocal.day))
      .inDays;
  // 同步时间在未来（设备时间设错）也归入「可能不准」，与 future_sync 一致。
  if (days < 0 || days >= syncStaleAfterDays) return SyncStatus.stale;
  return SyncStatus.fresh;
}

/// 徽章上的文字。只陈述数据新旧，不说设备好坏。
String syncStatusLabel(SyncStatus status) => switch (status) {
  SyncStatus.never => '尚未同步',
  SyncStatus.stale => '数据可能不是最新',
  SyncStatus.fresh => '已同步',
};
