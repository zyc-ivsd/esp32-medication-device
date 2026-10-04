import '../models/assistant_context.dart';

/// 观察项级别。[attention] 表示用户可能需要采取设备侧的维护动作。
enum ObservationLevel { info, attention }

/// 规则引擎输出的单条事实观察。
///
/// [code] 是稳定的机器标识，便于测试与以后对齐在线助手；
/// [text] 是面向用户的结论，必须只陈述事实。
class AssistantObservation {
  const AssistantObservation(this.code, this.text, this.level);

  final String code;
  final String text;
  final ObservationLevel level;
}

/// 超过这个天数未同步就给出提醒。
const int syncStaleAfterDays = 3;

/// 本地专家系统的规则层：只根据统计摘要做确定性判断。
///
/// 设计约束（与仓库文档一致）：
/// - 只陈述事实，不做诊断、不给剂量建议、不修改记录；
/// - “没有设备记录”不能表述为“漏服”，次数只代表设备动作；
/// - 结论必须能由摘要字段推出，便于单测和人工复核；
/// - 需要当前时间时必须由调用方传入，规则函数本身不读取系统时钟。
List<AssistantObservation> evaluateObservations(
  AssistantContext context, {
  required DateTime now,
}) {
  if (context.totalCount == 0) {
    return const [
      AssistantObservation(
        'no_records',
        'There are no saved records yet.',
        ObservationLevel.info,
      ),
    ];
  }

  final observations = <AssistantObservation>[];
  final windowDays = context.dailyCounts.length;

  if (context.lastSyncAt == null) {
    observations.add(
      const AssistantObservation(
        'never_synced',
        'No completed sync has been recorded. These statistics use only records saved on this phone.',
        ObservationLevel.attention,
      ),
    );
  }

  final blankDays = context.dailyCounts.where((count) => count == 0).length;
  if (blankDays > 0) {
    observations.add(
      AssistantObservation(
        'blank_days',
        '$blankDays of the last $windowDays days have no device records. '
            'A missing record does not establish a missed dose.',
        ObservationLevel.info,
      ),
    );
  }

  final activeDays = context.dailyCounts.where((count) => count > 0).toList();
  if (activeDays.length >= 2) {
    final lowest = activeDays.reduce((a, b) => a < b ? a : b);
    final highest = activeDays.reduce((a, b) => a > b ? a : b);
    if (highest - lowest >= 2) {
      observations.add(
        AssistantObservation(
          'uneven_days',
          'Daily counts on days with records range from $lowest to $highest. '
              'Logged uses do not verify ingestion.',
          ObservationLevel.info,
        ),
      );
    }
  }

  var trailingBlankDays = 0;
  for (final count in context.dailyCounts.reversed) {
    if (count != 0) break;
    trailingBlankDays++;
  }
  if (trailingBlankDays >= 2) {
    const advice =
        'If you are still using the device, check its battery, button and Bluetooth sync.';
    observations.add(
      AssistantObservation(
        'recent_gap',
        'There have been no device records for $trailingBlankDays consecutive days, including today. $advice',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.unknownTimeCount > 0) {
    const advice = '; check the device clock and sync again';
    observations.add(
      AssistantObservation(
        'unknown_time',
        '${context.unknownTimeCount} records have unknown times and are excluded from daily counts$advice.',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.futureTimeCount > 0) {
    const advice = '; check the device clock';
    observations.add(
      AssistantObservation(
        'future_time',
        '${context.futureTimeCount} records are dated after the current time and are excluded from daily counts$advice.',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.invalidEventCount > 0) {
    observations.add(
      AssistantObservation(
        'invalid_events',
        '${context.invalidEventCount} suspected invalid uses were recorded in the last $windowDays days. '
            'Inspect their original details in History.',
        ObservationLevel.attention,
      ),
    );
  }

  final lastSync = context.lastSyncAt?.toLocal();
  if (lastSync != null) {
    final localNow = now.toLocal();
    // 按日历天比较，避免夏令时 23/25 小时造成的取整误差。
    final staleDays = DateTime(
      localNow.year,
      localNow.month,
      localNow.day,
    ).difference(DateTime(lastSync.year, lastSync.month, lastSync.day)).inDays;
    if (staleDays < 0) {
      // 同步时间在未来时差值为负，stale_sync 会静默不触发；而 future_time 只看
      // 记录时间、不看同步时间，所以设备时间被设错时原本不会有任何提示。
      const advice = '; check the device clock and sync again';
      observations.add(
        const AssistantObservation(
          'future_sync',
          'The last sync time is in the future. Daily statistics may be inaccurate$advice.',
          ObservationLevel.attention,
        ),
      );
    } else if (staleDays >= syncStaleAfterDays) {
      observations.add(
        AssistantObservation(
          'stale_sync',
          'The last sync was $staleDays days ago. New records may be missing. '
              'Open Device connection to sync again.',
          ObservationLevel.attention,
        ),
      );
    }
  }

  return observations;
}
