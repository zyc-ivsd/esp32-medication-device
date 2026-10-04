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
        '当前还没有任何记录。',
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
        '还没有记录过同步时间，无法判断数据新旧；下面的统计只基于本机已有数据。',
        ObservationLevel.attention,
      ),
    );
  }

  final blankDays = context.dailyCounts.where((count) => count == 0).length;
  if (blankDays > 0) {
    observations.add(AssistantObservation(
      'blank_days',
      '近 $windowDays 天中有 $blankDays 天没有设备记录。'
          '这只说明当天没有设备动作，不能确认是否服药。',
      ObservationLevel.info,
    ));
  }

  final activeDays = context.dailyCounts.where((count) => count > 0).toList();
  if (activeDays.length >= 2) {
    final lowest = activeDays.reduce((a, b) => a < b ? a : b);
    final highest = activeDays.reduce((a, b) => a > b ? a : b);
    if (highest - lowest >= 2) {
      observations.add(AssistantObservation(
        'uneven_days',
        '有记录的日次数在 $lowest–$highest 之间波动，分布不均匀。'
            '设备动作次数不等于服药次数。',
        ObservationLevel.info,
      ));
    }
  }

  var trailingBlankDays = 0;
  for (final count in context.dailyCounts.reversed) {
    if (count != 0) break;
    trailingBlankDays++;
  }
  if (trailingBlankDays >= 2) {
    const advice = '若装置仍在使用，建议检查电量、按键和蓝牙同步是否正常。';
    observations.add(
      AssistantObservation(
        'recent_gap',
        '到今天为止已连续 $trailingBlankDays 天没有设备记录。$advice',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.unknownTimeCount > 0) {
    const advice = '，建议为设备校时后重新同步';
    observations.add(
      AssistantObservation(
        'unknown_time',
        '有 ${context.unknownTimeCount} 条记录缺少时间信息，无法计入按日统计$advice。',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.futureTimeCount > 0) {
    const advice = '，建议核对设备时间设置';
    observations.add(
      AssistantObservation(
        'future_time',
        '有 ${context.futureTimeCount} 条记录的时间晚于当前时间，已排除在按日统计之外$advice。',
        ObservationLevel.attention,
      ),
    );
  }

  if (context.invalidEventCount > 0) {
    observations.add(AssistantObservation(
      'invalid_events',
      '近 $windowDays 天有 ${context.invalidEventCount} 条疑似无效事件，'
          '可在历史记录中查看原始信息。',
      ObservationLevel.attention,
    ));
  }

  final lastSync = context.lastSyncAt?.toLocal();
  if (lastSync != null) {
    final localNow = now.toLocal();
    // 按日历天比较，避免夏令时 23/25 小时造成的取整误差。
    final staleDays = DateTime(localNow.year, localNow.month, localNow.day)
        .difference(DateTime(lastSync.year, lastSync.month, lastSync.day))
        .inDays;
    if (staleDays < 0) {
      // 同步时间在未来时差值为负，stale_sync 会静默不触发；而 future_time 只看
      // 记录时间、不看同步时间，所以设备时间被设错时原本不会有任何提示。
      const advice = '，建议核对设备时间设置后重新同步';
      observations.add(
        const AssistantObservation(
          'future_sync',
          '同步时间晚于当前时间，按日统计可能不准确$advice。',
          ObservationLevel.attention,
        ),
      );
    } else if (staleDays >= syncStaleAfterDays) {
      observations.add(AssistantObservation(
        'stale_sync',
        '距上次同步已 $staleDays 天，统计可能不含最新记录，'
            '建议在概览页重新同步设备。',
        ObservationLevel.attention,
      ));
    }
  }

  return observations;
}
