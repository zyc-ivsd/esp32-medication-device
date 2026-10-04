import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/answer_styling.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';

void main() {
  test('声明在最前、个人数据数字单独标蓝', () {
    const text =
        '(General AI health information, not your device records. Consult a clinician for health decisions.)'
        '\n\n近 7 天共 3 次使用动作。';
    final spans = styleAnswer(text, dataNumbers: const {3, 7});

    expect(spans.first.kind, AnswerSpanKind.notice);
    expect(spans.first.text, contains('not your device records'));

    // 「7」后面是「天」不是次数单位，不标蓝；「3」后面是「次」，标蓝。
    final data = spans
        .where((s) => s.kind == AnswerSpanKind.data)
        .map((s) => s.text)
        .toList();
    expect(data, ['3']);
  });

  test('结尾「提醒」标成问题', () {
    const text =
        '本周记录了 12 次使用动作。\n\n'
        '（提醒：本次回答里的 12 与当前统计摘要对不上，请以概览页的数字为准。）';
    final spans = styleAnswer(text);
    expect(spans.last.kind, AnswerSpanKind.alert);
    expect(spans.last.text, contains('提醒'));
  });

  test('本地「需要留意」尾巴标成问题', () {
    const text = '今天使用 2 次。\n需要留意：有记录的时间晚于当前时间。';
    final spans = styleAnswer(text, dataNumbers: const {2});
    expect(spans.last.kind, AnswerSpanKind.alert);
    expect(spans.last.text, contains('需要留意'));
  });

  test('没有数据数字时整段当正文、不拆', () {
    final spans = styleAnswer('近 7 天共 3 次。', dataNumbers: const {});
    expect(spans, hasLength(1));
    expect(spans.single.kind, AnswerSpanKind.plain);
    expect(spans.single.text, '近 7 天共 3 次。');
  });

  test('闲聊里的数字即使数值撞上摘要也不标蓝', () {
    const text = '你今年 50 岁，每天睡 8 小时，全球约 3 亿人受影响。';
    final spans = styleAnswer(text, dataNumbers: const {50, 8, 3});
    expect(spans.where((s) => s.kind == AnswerSpanKind.data), isEmpty);
  });

  test('personalDataNumbers 收集摘要里的原始数字', () {
    const context = AssistantContext(
      todayCount: 2,
      last7DaysCount: 3,
      totalCount: 9,
      dailyCounts: [0, 1, 0, 0, 1, 0, 1],
    );
    expect(personalDataNumbers(context), containsAll({2, 3, 9, 0, 1, 7}));
  });
}
