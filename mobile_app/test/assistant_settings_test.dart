import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_settings.dart';

void main() {
  test('默认值：多轮关、自动朗读关、正常语速与音调、大字关', () {
    expect(AssistantSettings.defaults.sendHistory, isFalse);
    expect(AssistantSettings.defaults.autoSpeak, isFalse);
    expect(AssistantSettings.defaults.speechRate, 0.5);
    expect(AssistantSettings.defaults.speechPitch, 1.0);
    expect(AssistantSettings.defaults.largeText, isFalse);
  });

  test('JSON 往返保持原值', () {
    const settings = AssistantSettings(
      sendHistory: true,
      autoSpeak: true,
      speechRate: 0.8,
      speechPitch: 1.3,
      largeText: true,
    );
    expect(AssistantSettings.fromJson(settings.toJson()).sendHistory, isTrue);
    expect(AssistantSettings.fromJson(settings.toJson()).autoSpeak, isTrue);
    expect(AssistantSettings.fromJson(settings.toJson()).speechRate, 0.8);
    expect(AssistantSettings.fromJson(settings.toJson()).speechPitch, 1.3);
    expect(AssistantSettings.fromJson(settings.toJson()).largeText, isTrue);
  });

  test('坏档、缺字段或非数值一律退回默认值，不抛异常', () {
    expect(AssistantSettings.fromJson(null).sendHistory, isFalse);
    expect(AssistantSettings.fromJson('不是对象').autoSpeak, isFalse);
    expect(AssistantSettings.fromJson(const {'send_history': 'yes'}).sendHistory,
        isFalse);
    expect(AssistantSettings.fromJson(const {'speech_rate': '快'}).speechRate,
        0.5);
    expect(
      AssistantSettings.fromJson(const {'speech_pitch': 99}).speechPitch,
      99,
      reason: '合法数值即使超出滑杆范围也原样读回，交给滑杆钳制',
    );
  });
}
