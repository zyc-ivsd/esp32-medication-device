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

  test('assistant context keys match the gateway contract', () {
    expect(context.toJson().keys.toSet(), {
      'today_count',
      'last_7_days_count',
      'invalid_event_count',
      'unknown_time_count',
      'future_time_count',
      'total_count',
      'is_demo',
      'last_sync_at',
      'daily_counts',
    });
  });

  test('mock assistant answers usage question', () async {
    final answer = await AssistantService().ask(
      question: 'How many uses today?',
      context: context,
    );

    expect(answer.text, contains('2 uses today'));
  });
}
