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
    final answer = await ask('Is my data up to date?');
    expect(answer, contains('Last completed sync'));
    expect(answer, contains('Sync time describes freshness'));

    // 「多久没同步」走同一条分支。
    expect(await ask('多久没同步了'), contains('Last completed sync'));
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
    expect(answer, contains('Last completed sync'));
    expect(answer, contains('days'), reason: 'stale_sync 会给出已过天数');
  });

  test('从没同步过时说清无法判断新旧，不编一个时间', () async {
    final answer = await ask(
      '同步了吗',
      const AssistantContext(totalCount: 3, last7DaysCount: 1),
    );
    expect(answer, contains('No completed sync'));
    expect(answer, isNot(contains('Last completed sync:')));
  });

  test('问设备时间：报时间未知与未来时间两条，并给校时建议', () async {
    final answer = await ask('Is the device clock correct?');
    expect(answer, contains('unknown-time'));
    expect(answer, contains('future-time'));
    expect(answer, contains('Calibrate'));
  });

  test('问总条数：给出总量与今日、近 7 天', () async {
    for (final question in ['How many records are saved?', '总共多少条', '总量是多少']) {
      final answer = await ask(question);
      expect(answer, contains('9 records'), reason: question);
      expect(answer, contains('2 uses today'), reason: question);
      expect(answer, contains('3 uses in the last 7 days'), reason: question);
    }
  });

  test('问空白那几天：只报逐日事实与空档，不解释成漏服', () async {
    final answer = await ask('What do days without records mean?');
    expect(answer, contains('Daily uses'));
    expect(
      answer,
      contains('A missing record does not establish a missed dose'),
    );
    expect(answer, isNot(contains('漏服')));
  });

  test('数据库为空时问空白：说目前没有记录，不说七天都有记录', () async {
    final answer = await ask(
      'What do days without records mean?',
      const AssistantContext(totalCount: 0),
    );
    expect(answer, contains('There are no saved records'));
    expect(answer, isNot(contains('Each of the last 7 days has records')));
  });

  test('涉及服药判断的问法一律不给结论', () async {
    for (final question in ['我今天漏服了吗？', '该不该补吃一次？', '要不要加量', '这个副作用正常吗']) {
      final answer = await ask(question, device);
      expect(
        answer,
        contains('Device records cannot establish this'),
        reason: question,
      );
      // 关键：不能顺手把今天的次数报出来，那会被读成「吃过了」。
      expect(answer, isNot(contains('今天使用')), reason: question);
      expect(answer, contains('clinician'), reason: question);
    }
  });

  test('数据类回答不出现诊断、剂量、漏服的表述', () async {
    for (final question in [
      'How many uses today?',
      'Any invalid uses recently?',
      'Show the last week',
      'What needs attention?',
      'Is my data up to date?',
      'Is the device clock correct?',
      'How many records are saved?',
      'What do days without records mean?',
    ]) {
      final answer = await ask(question);
      for (final forbidden in ['漏服', '剂量', '诊断', '停药']) {
        expect(
          answer,
          isNot(contains(forbidden)),
          reason: '$question / $forbidden',
        );
      }
    }
  });

  test('兜底不再只丢一句摘要，而是说清能问什么、答不了什么', () async {
    final answer = await ask('介绍一下哮喘');
    expect(answer, contains('Local uses fixed rules to explain saved records'));
    expect(answer, contains('Online'));
    expect(answer, contains('Current summary'));
    // 兜底也不该把通用知识问题硬说成记录结论。
    expect(answer, isNot(contains('今天使用')));
  });

  test('空问题仍然先要求输入', () async {
    expect(await ask('   '), 'Enter a question first.');
  });

  test('连不上/同步失败走排查步骤，不报最后同步时间', () async {
    for (final question in [
      '连不上蓝牙了',
      'What should I do when sync fails?',
      '扫描不到设备',
    ]) {
      final answer = await ask(question);
      expect(answer, contains('scan again'), reason: question);
      expect(answer, isNot(contains('Last completed sync')), reason: question);
      expect(
        answer,
        contains('does not delete device files'),
        reason: question,
      );
    }
  });

  test('数据来源说明只指向设备同步', () async {
    final answer = await ask('设备数据从哪里来', device);
    expect(answer, contains('connect and sync'));
    expect(answer, isNot(contains('演示')));
  });

  test('问导出：指向历史记录页 CSV，且不含凭据', () async {
    for (final question in ['怎么导出记录', '能分享成表格吗', '导成 CSV']) {
      final answer = await ask(question);
      expect(answer, contains('CSV'), reason: question);
      expect(answer, contains('credentials'), reason: question);
    }
  });

  test('问能做什么：列出能力，不出现医疗判断表述', () async {
    for (final question in ['你能做什么', 'What can I ask?', '怎么用这个助手']) {
      final answer = await ask(question);
      expect(answer, contains('fixed local rules'), reason: question);
      expect(answer, contains('Online'), reason: question);
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
      'What should I do when sync fails?',
      '数据来源是什么',
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
      '设备数据从哪里来': 'connect and sync',
      '怎么清空对话': 'Clear chat',
      '怎么搜索历史': 'Search',
      'Can answers be read aloud?': 'Read aloud',
      '字太小了怎么办': 'Larger text',
      '怎么联网': 'Online',
    };
    for (final entry in cases.entries) {
      final answer = await ask(entry.key);
      expect(answer, contains(entry.value), reason: entry.key);
      expect(
        answer,
        isNot(contains('Local uses fixed rules')),
        reason: '「${entry.key}」落到了兜底，说明没有对应的规则分支',
      );
    }
  });

  test('App 功能求助的回答也不出现医疗判断表述', () async {
    for (final question in [
      '设备数据从哪里来',
      '怎么清空对话',
      '怎么搜索历史',
      'Can answers be read aloud?',
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
