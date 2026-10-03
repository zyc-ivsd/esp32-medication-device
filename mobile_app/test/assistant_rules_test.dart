import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/providers/mock_assistant_provider.dart';
import 'package:medication_device_app/assistant/rules/observation_rules.dart';

void main() {
  // Fixed local clock so calendar-day rules are deterministic.
  final now = DateTime(2026, 9, 29, 10);

  List<String> codesOf(AssistantContext context) =>
      evaluateObservations(context, now: now)
          .map((observation) => observation.code)
          .toList();

  test('没有记录时直接返回，不推断其它结论', () {
    expect(codesOf(const AssistantContext()), ['no_records']);
  });

  test('空白日与最近的连续空白日分别标记', () {
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 8,
        last7DaysCount: 5,
        dailyCounts: const [2, 0, 3, 0, 0, 0, 0],
        lastSyncAt: DateTime(2026, 9, 28),
      ),
      now: now,
    );
    final blank = observations.firstWhere((item) => item.code == 'blank_days');
    expect(blank.text, contains('5 天没有设备记录'));
    expect(blank.level, ObservationLevel.info);
    final gap = observations.firstWhere((item) => item.code == 'recent_gap');
    expect(gap.text, contains('连续 4 天'));
    expect(gap.level, ObservationLevel.attention);
  });

  test('波动只在有记录的日之间比较，且不下结论', () {
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 6,
        last7DaysCount: 6,
        dailyCounts: const [0, 1, 0, 5, 0, 0, 0],
        lastSyncAt: DateTime(2026, 9, 29),
      ),
      now: now,
    );
    final uneven = observations.firstWhere((item) => item.code == 'uneven_days');
    expect(uneven.text, contains('1–5'));
    expect(uneven.text, contains('不等于服药次数'));
    // 单日只有 1 次时不应报波动。
    expect(
      codesOf(AssistantContext(
        totalCount: 2,
        last7DaysCount: 2,
        dailyCounts: const [0, 1, 0, 1, 0, 0, 0],
        lastSyncAt: DateTime(2026, 9, 29),
      )),
      isNot(contains('uneven_days')),
    );
  });

  test('数据质量问题与疑似无效事件各自独立成项', () {
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 12,
        last7DaysCount: 4,
        invalidEventCount: 3,
        unknownTimeCount: 2,
        futureTimeCount: 1,
        dailyCounts: const [0, 0, 2, 0, 2, 0, 0],
        lastSyncAt: DateTime(2026, 9, 29),
      ),
      now: now,
    );
    final codes = observations.map((item) => item.code).toSet();
    expect(
      codes,
      containsAll({'invalid_events', 'unknown_time', 'future_time'}),
    );
    for (final code in ['invalid_events', 'unknown_time', 'future_time']) {
      expect(
        observations.firstWhere((item) => item.code == code).level,
        ObservationLevel.attention,
      );
    }
  });

  test('同步过旧按日历天判断，边界为三天', () {
    List<String> codesForSync(DateTime? lastSyncAt) => codesOf(
          AssistantContext(
            totalCount: 3,
            last7DaysCount: 1,
            dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
            lastSyncAt: lastSyncAt,
          ),
        );

    expect(codesForSync(DateTime(2026, 9, 29, 1)), isNot(contains('stale_sync')));
    expect(codesForSync(const AssistantContext().lastSyncAt),
        contains('never_synced'));
    // 26 日到 29 日恰好三天，按“至少三天”提醒。
    expect(codesForSync(DateTime(2026, 9, 26, 23)), contains('stale_sync'));
    final stale = evaluateObservations(
      AssistantContext(
        totalCount: 3,
        last7DaysCount: 1,
        dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
        lastSyncAt: DateTime(2026, 9, 20),
      ),
      now: now,
    ).firstWhere((item) => item.code == 'stale_sync');
    expect(stale.text, contains('已 9 天'));
  });

  test('同步时间晚于当前时间时单独提醒，而不是静默跳过', () {
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 3,
        last7DaysCount: 1,
        dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
        lastSyncAt: DateTime(2026, 10, 2, 9),
      ),
      now: now,
    );
    final future = observations.firstWhere((item) => item.code == 'future_sync');
    expect(future.text, contains('晚于当前时间'));
    expect(future.text, contains('核对设备时间'));
    expect(future.level, ObservationLevel.attention);
    // 差值为负，stale_sync 本来就触发不了，所以必须由 future_sync 兜住。
    expect(
      observations.map((item) => item.code),
      isNot(contains('stale_sync')),
    );
    for (final forbidden in ['漏服', '剂量', '诊断', '停药', '加药']) {
      expect(future.text, isNot(contains(forbidden)));
    }
  });

  test('演示数据的未来同步时间同样不给设备维护建议', () {
    // 演示源写不进 lastSyncAt，这里直接构造，确认两套文案确实分开了。
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 3,
        last7DaysCount: 1,
        dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
        lastSyncAt: DateTime(2026, 10, 2, 9),
        isDemo: true,
      ),
      now: now,
    );
    expect(
      observations.firstWhere((item) => item.code == 'future_sync').text,
      isNot(contains('核对设备时间')),
    );
  });

  test('任何观察文本都不出现诊断或剂量类结论', () {
    final observations = evaluateObservations(
      AssistantContext(
        totalCount: 20,
        last7DaysCount: 6,
        invalidEventCount: 2,
        unknownTimeCount: 1,
        futureTimeCount: 1,
        dailyCounts: const [1, 0, 3, 0, 0, 2, 0],
        lastSyncAt: DateTime(2026, 9, 1),
      ),
      now: now,
    );
    expect(observations, isNotEmpty);
    for (final observation in observations) {
      for (final forbidden in ['漏服', '剂量', '诊断', '停药', '加药']) {
        expect(
          observation.text,
          isNot(contains(forbidden)),
          reason: '${observation.code} 不应包含「$forbidden」',
        );
      }
    }
  });

  test('演示数据不提示同步状态，也不给设备维护建议', () {
    const demo = AssistantContext(
      totalCount: 5,
      last7DaysCount: 2,
      unknownTimeCount: 1,
      futureTimeCount: 1,
      dailyCounts: [0, 1, 0, 0, 0, 0, 1],
      isDemo: true,
    );
    final demoObservations = evaluateObservations(demo, now: now);
    expect(
      demoObservations.map((item) => item.code),
      isNot(contains('never_synced')),
    );
    for (final observation in demoObservations) {
      expect(observation.text, isNot(contains('设备校时')));
      expect(observation.text, isNot(contains('核对设备时间')));
    }

    const device = AssistantContext(
      totalCount: 5,
      last7DaysCount: 2,
      unknownTimeCount: 1,
      futureTimeCount: 1,
      dailyCounts: [0, 1, 0, 0, 0, 0, 1],
    );
    final deviceObservations = evaluateObservations(device, now: now);
    expect(
      deviceObservations.map((item) => item.code),
      contains('never_synced'),
    );
    expect(
      deviceObservations.firstWhere((item) => item.code == 'unknown_time').text,
      contains('设备校时'),
    );
    expect(
      deviceObservations.firstWhere((item) => item.code == 'future_time').text,
      contains('核对设备时间'),
    );
  });

  test('本地助手把需要留意的观察追加到具体回答之后', () async {
    final answer = await MockAssistantProvider(now: now).reply(
      question: '今天用了几次？',
      // 这次没有 lastSyncAt，参数全是常量，所以这里可以用 const。
      // 注意 dailyCounts 不能再写 const：在 const 上下文中它已经是常量，
      // 重复标注会触发 unnecessary_const。
      context: const AssistantContext(
        totalCount: 9,
        last7DaysCount: 3,
        unknownTimeCount: 2,
        dailyCounts: [0, 1, 0, 2, 0, 0, 0],
        isDemo: true,
      ),
    );
    expect(answer, contains('今天使用 0 次'));
    expect(answer, contains('需要留意'));
    expect(answer, contains('缺少时间信息'));
  });

  test('“建议”入口只输出事实观察', () async {
    final answer = await MockAssistantProvider(now: now).reply(
      question: '有什么建议？',
      context: AssistantContext(
        totalCount: 9,
        last7DaysCount: 3,
        invalidEventCount: 1,
        dailyCounts: const [0, 1, 0, 2, 0, 0, 0],
        lastSyncAt: DateTime(2026, 9, 29),
      ),
    );
    expect(answer, contains('不是医疗建议'));
    expect(answer, contains('疑似无效事件'));
    expect(answer, contains('不能确认实际服药'));
    expect(answer, isNot(contains('漏服')));
    expect(answer, isNot(contains('剂量')));
  });
}
