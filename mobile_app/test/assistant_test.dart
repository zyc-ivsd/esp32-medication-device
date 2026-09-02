import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';

void main() {
  const context = AssistantContext(
    todayCount: 2,
    last7DaysCount: 12,
    invalidEventCount: 1,
  );

  test('assistant context can be serialized', () {
    expect(context.toJson()['today_count'], 2);
    expect(context.toJson()['last_7_days_count'], 12);
  });

  test('mock assistant answers usage question', () async {
    final answer = await AssistantService().ask(
      question: '今天用了几次？',
      context: context,
    );

    expect(answer.text, contains('今天使用 2 次'));
  });
}
