import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/providers/mock_assistant_provider.dart';

void main() {
  // 固定时钟：规则层里「距上次同步几天」之类要按天算，不能读系统时间。
  final now = DateTime(2026, 9, 29, 10);
  final provider = MockAssistantProvider(now: now);

  final device = AssistantContext(
    todayCount: 2,
    last7DaysCount: 3,
    invalidEventCount: 1,
    unknownTimeCount: 1,
    futureTimeCount: 1,
    totalCount: 9,
    dailyCounts: const [0, 1, 0, 0, 1, 0, 1],
    lastSyncAt: DateTime(2026, 9, 28, 8),
  );

  Future<String> ask(String question, [AssistantContext? context]) =>
      provider.reply(question: question, context: context ?? device);

  test('问数据新旧：报最后同步时间，并说明同步只影响统计新旧', () async {
    final answer = await ask('数据是最新的吗？');
    expect(answer, contains('最后一次同步'));
    expect(answer, contains('同步时间只反映本机数据的新旧'));

    // 「多久没同步」走同一条分支。
    expect(await ask('多久没同步了'), contains('最后一次同步'));
  });

  test('同步过旧时补上规则层的原话，而不是另写一套', () async {
    final stale = AssistantContext(
      todayCount: 1,
      last7DaysCount: 1,
      totalCount: 5,
      dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
      lastSyncAt: DateTime(2026, 9, 10),
    );
    final answer = await ask('最后一次同步是什么时候', stale);
    expect(answer, contains('最后一次同步'));
    expect(answer, contains('天'), reason: 'stale_sync 会给出已过天数');
  });

  test('从没同步过时说清无法判断新旧，不编一个时间', () async {
    final answer = await ask(
      '同步了吗',
      const AssistantContext(totalCount: 3, last7DaysCount: 1),
    );
    expect(answer, contains('无法判断数据新旧'));
    expect(answer, isNot(contains('最后一次同步是')));
  });

  test('演示数据没有同步时间，也不提设备同步', () async {
    final answer = await ask(
      '数据是最新的吗',
      const AssistantContext(isDemo: true, totalCount: 3, last7DaysCount: 1),
    );
    expect(answer, contains('演示数据没有设备同步时间'));
  });

  test('问设备时间：报时间未知与未来时间两条，并给校时建议', () async {
    final answer = await ask('设备时间对吗？');
    expect(answer, contains('时间未知'));
    expect(answer, contains('时间晚于当前时间'));
    expect(answer, contains('校时'));
  });

  test('演示数据只陈述时间问题，不给校时建议', () async {
    // 演示数据没有设备可维护，说「去设备上校时」只会让人去找一个不存在的东西。
    final answer = await ask(
      '时间是不是不对',
      const AssistantContext(
        isDemo: true,
        totalCount: 3,
        last7DaysCount: 1,
        unknownTimeCount: 1,
        dailyCounts: [0, 0, 0, 0, 1, 0, 0],
      ),
    );
    expect(answer, contains('时间未知'));
    expect(answer, isNot(contains('校时')));
  });

  test('问总条数：给出总量与今日、近 7 天', () async {
    for (final question in ['一共有多少条记录？', '总共多少条', '总量是多少']) {
      final answer = await ask(question);
      expect(answer, contains('共 9 条'), reason: question);
      expect(answer, contains('今天 2 次'), reason: question);
      expect(answer, contains('近 7 天 3 次'), reason: question);
    }
  });

  test('问空白那几天：只报逐日事实与空档，不解释成漏服', () async {
    final answer = await ask('空白那几天怎么看？');
    expect(answer, contains('逐日'));
    expect(answer, contains('没有记录只说明当天没有设备动作'));
    expect(answer, isNot(contains('漏服')));
  });

  test('数据库为空时问空白：说目前没有记录，不说七天都有记录', () async {
    final answer = await ask(
      '空白那几天怎么看？',
      const AssistantContext(totalCount: 0),
    );
    expect(answer, contains('目前没有记录'));
    expect(answer, isNot(contains('都有记录')));
  });

  test('涉及服药判断的问法一律不给结论', () async {
    for (final question in [
      '我今天漏服了吗？',
      '该不该补吃一次？',
      '要不要加量',
      '这个副作用正常吗',
    ]) {
      final answer = await ask(question, device);
      expect(answer, contains('不该由设备记录来回答'), reason: question);
      // 关键：不能顺手把今天的次数报出来，那会被读成「吃过了」。
      expect(answer, isNot(contains('今天使用')), reason: question);
      expect(answer, contains('医生'), reason: question);
    }
  });

  test('数据类回答不出现诊断、剂量、漏服的表述', () async {
    for (final question in [
      '今天用了几次？',
      '最近有异常吗？',
      '查看最近一周',
      '有什么建议？',
      '数据是最新的吗？',
      '设备时间对吗？',
      '一共有多少条记录？',
      '空白那几天怎么看？',
    ]) {
      final answer = await ask(question);
      for (final forbidden in ['漏服', '剂量', '诊断', '停药']) {
        expect(answer, isNot(contains(forbidden)), reason: '$question / $forbidden');
      }
    }
  });

  test('兜底不再只丢一句摘要，而是说清能问什么、答不了什么', () async {
    final answer = await ask('介绍一下哮喘');
    expect(answer, contains('本地模式只按固定规则解释你的记录'));
    expect(answer, contains('在线'));
    expect(answer, contains('当前记录摘要'));
    // 兜底也不该把通用知识问题硬说成记录结论。
    expect(answer, isNot(contains('今天使用')));
  });

  test('空问题仍然先要求输入', () async {
    expect(await ask('   '), '请先输入问题。');
  });

  test('连不上/同步失败走排查步骤，不报最后同步时间', () async {
    for (final question in ['连不上蓝牙了', '同步失败怎么办', '扫描不到设备']) {
      final answer = await ask(question);
      expect(answer, contains('重新扫描'), reason: question);
      expect(answer, isNot(contains('最后一次同步')), reason: question);
      expect(answer, contains('不会删除设备上的记录'), reason: question);
    }
  });

  test('问演示数据来源：演示时说清是示例，真机时说来自同步', () async {
    final demoAnswer = await ask(
      '这是演示数据吗',
      const AssistantContext(isDemo: true, totalCount: 3, last7DaysCount: 1),
    );
    expect(demoAnswer, contains('演示数据'));

    final deviceAnswer = await ask('这是演示数据吗', device);
    expect(deviceAnswer, contains('不是演示数据'));
  });

  test('问导出：指向历史记录页 CSV，且不含凭据', () async {
    for (final question in ['怎么导出记录', '能分享成表格吗', '导成 CSV']) {
      final answer = await ask(question);
      expect(answer, contains('CSV'), reason: question);
      expect(answer, contains('凭据'), reason: question);
    }
  });

  test('问能做什么：列出能力，不出现医疗判断表述', () async {
    for (final question in ['你能做什么', '能问什么？', '怎么用这个助手']) {
      final answer = await ask(question);
      expect(answer, contains('按固定规则解释'), reason: question);
      expect(answer, contains('在线'), reason: question);
      for (final forbidden in ['诊断', '剂量', '漏服']) {
        expect(
          answer,
          isNot(contains(forbidden)),
          reason: '$question / $forbidden',
        );
      }
    }
  });

  test('新增分支的回答也不出现诊断、剂量、漏服、停药', () async {
    for (final question in [
      '蓝牙连不上',
      '同步失败怎么办',
      '这是演示数据吗',
      '怎么导出记录',
      '你能做什么',
    ]) {
      final answer = await ask(question);
      for (final forbidden in ['诊断', '剂量', '漏服', '停药']) {
        expect(
          answer,
          isNot(contains(forbidden)),
          reason: '$question / $forbidden',
        );
      }
    }
  });

  test('App 功能求助走本地分支，不落到兜底', () async {
    final cases = <String, String>{
      '怎么导入演示数据': '导入演示数据',
      '怎么清空对话': '清空对话',
      '怎么搜索历史': '搜索',
      '回答能朗读吗': '朗读',
      '字太小了怎么办': '大字模式',
      '怎么联网': '在线',
    };
    for (final entry in cases.entries) {
      final answer = await ask(entry.key);
      expect(answer, contains(entry.value), reason: entry.key);
      expect(
        answer,
        isNot(contains('本地模式只按固定规则解释')),
        reason: '「${entry.key}」落到了兜底，说明没有对应的规则分支',
      );
    }
  });

  test('App 功能求助的回答也不出现医疗判断表述', () async {
    for (final question in [
      '怎么导入演示数据',
      '怎么清空对话',
      '怎么搜索历史',
      '回答能朗读吗',
      '字太小了怎么办',
      '怎么联网',
    ]) {
      final answer = await ask(question);
      for (final forbidden in ['诊断', '剂量', '漏服', '停药']) {
        expect(
          answer,
          isNot(contains(forbidden)),
          reason: '$question / $forbidden',
        );
      }
    }
  });
}
