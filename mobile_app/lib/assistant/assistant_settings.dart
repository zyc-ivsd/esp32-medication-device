import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 助手页的本地偏好：多轮上下文开关、自动朗读、朗读语速/音调、大字模式。
///
/// 与聊天记录同属「便利」类偏好（见 `AssistantChatStore` 的注释）：
/// 读不到就用默认值，写不进去也只影响下次打开，不打断当前对话。
/// 这里**不存任何凭据**——凭据只走 `flutter_secure_storage`。
class AssistantSettings {
  const AssistantSettings({
    this.sendHistory = false,
    this.autoSpeak = false,
    this.speechRate = 0.5,
    this.speechPitch = 1.0,
    this.largeText = false,
  });

  /// 是否把本轮更早的问答带给在线模型（默认关）。
  final bool sendHistory;

  /// 回答后是否自动朗读（默认关）。
  final bool autoSpeak;

  /// 语速，flutter_tts 取值 0.0–1.0（0.5 为正常）。
  final double speechRate;

  /// 音调，flutter_tts 取值 0.5–2.0（1.0 为正常）。
  final double speechPitch;

  /// 大字模式（默认关）：把助手页整体字号放大一档，方便长辈阅读。
  final bool largeText;

  static const defaults = AssistantSettings();

  AssistantSettings copyWith({
    bool? sendHistory,
    bool? autoSpeak,
    double? speechRate,
    double? speechPitch,
    bool? largeText,
  }) => AssistantSettings(
    sendHistory: sendHistory ?? this.sendHistory,
    autoSpeak: autoSpeak ?? this.autoSpeak,
    speechRate: speechRate ?? this.speechRate,
    speechPitch: speechPitch ?? this.speechPitch,
    largeText: largeText ?? this.largeText,
  );

  Map<String, dynamic> toJson() => {
    'send_history': sendHistory,
    'auto_speak': autoSpeak,
    'speech_rate': speechRate,
    'speech_pitch': speechPitch,
    'large_text': largeText,
  };

  /// 解析偏好；任何无法识别的输入都退回默认值，调用方不用区分坏档。
  static AssistantSettings fromJson(Object? data) {
    if (data is! Map) return defaults;
    bool flag(Object? value, bool fallback) => value is bool ? value : fallback;
    double number(Object? value, double fallback) =>
        value is num ? value.toDouble() : fallback;
    return AssistantSettings(
      sendHistory: flag(data['send_history'], false),
      autoSpeak: flag(data['auto_speak'], false),
      speechRate: number(data['speech_rate'], 0.5),
      speechPitch: number(data['speech_pitch'], 1.0),
      largeText: flag(data['large_text'], false),
    );
  }
}

/// 偏好的读写接口。测试注入内存实现即可。
abstract class AssistantSettingsStore {
  Future<AssistantSettings> load();
  Future<void> save(AssistantSettings settings);
}

/// 用 `shared_preferences` 保存偏好。失败语义见 [AssistantSettings] 头注：
/// 全部静默降级，绝不因为读不到偏好而抛异常打断界面。
class SharedPreferencesAssistantSettingsStore
    implements AssistantSettingsStore {
  static const _key = 'assistant_settings';

  @override
  Future<AssistantSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      return AssistantSettings.fromJson(raw == null ? null : jsonDecode(raw));
    } catch (_) {
      return AssistantSettings.defaults;
    }
  }

  @override
  Future<void> save(AssistantSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(settings.toJson()));
    } catch (_) {
      // 没存上只是下次打开回到默认值，不打断当前对话。
    }
  }
}
