import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/follow_up_suggestions.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/providers/mock_assistant_provider.dart';

const _context = AssistantContext(
  todayCount: 2,
  last7DaysCount: 3,
  totalCount: 9,
  dailyCounts: [0, 1, 0, 0, 1, 0, 1],
);

void main() {
  test('每个追问都命中本地分支、不落到兜底', () async {
    final provider = MockAssistantProvider();
    final topics = [
      '今天用了几次？',
      '最近有异常吗？',
      '查看最近一周',
      '数据是最新的吗？',
      '设备时间对吗？',
      '空白那几天怎么看？',
    ];
    final followUps = <String>{};
    for (final topic in topics) {
      followUps.addAll(followUpsFor(topic));
    }
    for (final question in followUps) {
      final answer = await provider.reply(question: question, context: _context);
      expect(
        answer,
        isNot(contains('本地模式只按固定规则解释')),
        reason: '「$question」落到了兜底',
      );
    }
  });

  test('按问句路由到对应主题', () {
    expect(followUpsFor('今天用了几次？'), contains('查看最近一周'));
    expect(followUpsFor('空白那几天怎么看？'), contains('设备时间对吗？'));
  });
}
