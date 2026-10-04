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
      'How many uses today?',
      'Any invalid uses recently?',
      'Show the last week',
      'Is my data up to date?',
      'Is the device clock correct?',
      'What do days without records mean?',
    ];
    final followUps = <String>{};
    for (final topic in topics) {
      followUps.addAll(followUpsFor(topic));
    }
    for (final question in followUps) {
      final answer = await provider.reply(
        question: question,
        context: _context,
      );
      expect(
        answer,
        isNot(contains('Local uses fixed rules')),
        reason: '「$question」落到了兜底',
      );
    }
  });

  test('按问句路由到对应主题', () {
    expect(
      followUpsFor('How many uses today?'),
      contains('Show the last week'),
    );
    expect(
      followUpsFor('What do days without records mean?'),
      contains('Is the device clock correct?'),
    );
  });
}
