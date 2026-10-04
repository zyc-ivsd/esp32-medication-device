import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/answer_verification.dart';
import 'package:medication_device_app/assistant/assistant_provider.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/models/chat_message.dart';

class _FixedProvider implements AssistantProvider {
  _FixedProvider(this.answer);

  final String answer;

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => answer;
}

void main() {
  // Fixed local clock so the rule engine's derived numbers are deterministic.
  final now = DateTime(2026, 9, 29, 10);

  const context = AssistantContext(
    todayCount: 2,
    last7DaysCount: 8,
    invalidEventCount: 1,
    unknownTimeCount: 1,
    totalCount: 21,
    dailyCounts: [0, 1, 0, 2, 0, 0, 5],
  );

  test('回答只用摘要里出现过的数字时不报警', () {
    expect(
      numbersNotInSummary(
        '今天使用 2 次，近 7 天共 8 次，逐日（最早在前）0、1、0、2、0、0、5，共 21 条记录。',
        context,
        now: now,
      ),
      isEmpty,
    );
  });

  test('凭空出现的次数会被指出', () {
    expect(numbersNotInSummary('本周记录了 12 次使用动作。', context, now: now), [12]);
  });

  test('闲聊里的数字（岁、小时、分钟）不触发回验', () {
    expect(
      numbersNotInSummary('一般建议 50 岁以上人群每年检查，每次约 30 分钟。', context, now: now),
      isEmpty,
    );
  });

  test('复述最后同步时间不会被当成编造', () {
    final withSync = AssistantContext(
      todayCount: 1,
      last7DaysCount: 1,
      totalCount: 1,
      dailyCounts: const [0, 0, 0, 0, 0, 0, 1],
      lastSyncAt: DateTime(2026, 9, 29, 8, 30),
    );
    expect(
      numbersNotInSummary(
        '最后同步于 ${withSync.lastSyncAt!.toLocal()}，共 1 条记录。',
        withSync,
        now: now,
      ),
      isEmpty,
    );
  });

  test('规则引擎算出来的派生数字可以被复述', () {
    // daily_counts 里有 5 天是 0，blank_days 会说「近 7 天中有 5 天没有设备记录」。
    // 5 是算出来的结论，模型复述它不算编造，否则每次都会误报。
    const derived = AssistantContext(
      todayCount: 0,
      last7DaysCount: 2,
      totalCount: 5,
      dailyCounts: [0, 1, 0, 0, 1, 0, 0],
    );
    expect(
      numbersNotInSummary('近 7 天有 5 天没有设备记录，且已连续 2 天没有记录。', derived, now: now),
      isEmpty,
    );
  });

  test('多个可疑数字去重后升序返回', () {
    expect(
      numbersNotInSummary('共 30 次，另有 12 条异常，30 次里包含 12 条。', context, now: now),
      [12, 30],
    );
  });

  test('回验只追加提醒，不改动回答本身', () {
    final verified = verifyRemoteAnswer('本周记录了 12 次。', context, now: now);
    expect(verified, startsWith('本周记录了 12 次。'));
    expect(verified, contains('12'));
    expect(verified, contains('does not match the current record summary'));
    expect(mismatchNotice(const []), isNull);
  });

  test('没有可疑数字时原文返回', () {
    expect(verifyRemoteAnswer('近 7 天共 8 次。', context, now: now), '近 7 天共 8 次。');
  });

  test('回验自身无法判断时放行，不阻断回答', () {
    // 超出 int 范围的长数字解析不出来；宁可放行，也不能让助手指望不上。
    const answer = '共 99999999999999999999 次。';
    expect(
      verifyRemoteAnswer(answer, const AssistantContext(), now: now),
      answer,
    );
    expect(verifyRemoteAnswer('', const AssistantContext(), now: now), '');
  });

  test('只有在线回答会被回验，本地回答保持原样', () async {
    const bogus = '本周记录了 12 次使用动作。';
    final remote = await AssistantService(
      provider: _FixedProvider(bogus),
      isRemote: true,
      now: now,
    ).ask(question: '最近怎么样？', context: context);
    expect(remote.text, contains('does not match the current record summary'));

    final local = await AssistantService(
      provider: _FixedProvider(bogus),
      now: now,
    ).ask(question: '最近怎么样？', context: context);
    expect(local.text, bogus);
  });

  test('结尾的来源标记会被拆掉，并按标记归类', () {
    final knowledge = parseRemoteAnswer('哮喘是一种慢性气道炎症。\n【来源】AI知识');
    expect(knowledge.isKnowledge, isTrue);
    expect(knowledge.body, '哮喘是一种慢性气道炎症。');

    final records = parseRemoteAnswer('近 7 天共 8 次。\n【来源】记录统计');
    expect(records.isKnowledge, isFalse);
    expect(records.body, '近 7 天共 8 次。');
    // 标记行本身不该出现在用户看到的气泡里：界面用来源小标表达同一件事。
    expect(records.body, isNot(contains('来源')));
  });

  test('没有标记、或标记不在结尾时原样返回', () {
    final plain = parseRemoteAnswer('近 7 天共 8 次。');
    expect(plain.body, '近 7 天共 8 次。');
    expect(plain.isKnowledge, isFalse);

    // 标记写在正文中间：宁可当没写，也不能把正文从中间截断。
    const middle = '【来源】AI知识\n哮喘的常见诱因包括尘螨与花粉。';
    expect(parseRemoteAnswer(middle).body, middle);
  });

  test('通用知识回答补上说明，且不参与数字回验', () async {
    // 「3 亿」「300」本来就不来自摘要，回验会把这种正常回答误判成编造，
    // 再补一句「与当前统计摘要对不上」——用户问的是哮喘，得到的是统计提醒。
    final message = await AssistantService(
      provider: _FixedProvider('全球约有 3 亿人患哮喘。\n【来源】AI知识'),
      isRemote: true,
      now: now,
    ).ask(question: '介绍一下哮喘', context: context);
    expect(message.source, ChatSource.knowledge);
    expect(message.text, contains('3 亿'));
    expect(message.text, contains('not your device records'));
    expect(
      message.text,
      isNot(contains('does not match the current record summary')),
    );
    expect(message.text, isNot(contains('【来源】')));
  });

  test('用到记录的回答标为在线来源，并保留数字回验', () async {
    final message = await AssistantService(
      provider: _FixedProvider('本周记录了 12 次。\n【来源】记录统计'),
      isRemote: true,
      now: now,
    ).ask(question: '最近怎么样？', context: context);
    expect(message.source, ChatSource.online);
    expect(message.text, contains('does not match the current record summary'));
    expect(message.text, isNot(contains('【来源】')));
  });

  test('本地回答的来源是本地', () async {
    final message = await AssistantService(
      provider: _FixedProvider('任意'),
    ).ask(question: '随便问问', context: context);
    expect(message.source, ChatSource.local);
  });
}
