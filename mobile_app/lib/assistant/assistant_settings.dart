import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AssistantSettings {
  const AssistantSettings({
    this.autoSpeak = false,
    this.speechRate = 0.5,
    this.speechPitch = 1.0,
    this.largeText = false,
  });
  final bool autoSpeak;
  final double speechRate;
  final double speechPitch;
  final bool largeText;

  static const defaults = AssistantSettings();

  AssistantSettings copyWith({
    bool? autoSpeak,
    double? speechRate,
    double? speechPitch,
    bool? largeText,
  }) => AssistantSettings(
    autoSpeak: autoSpeak ?? this.autoSpeak,
    speechRate: speechRate ?? this.speechRate,
    speechPitch: speechPitch ?? this.speechPitch,
    largeText: largeText ?? this.largeText,
  );

  Map<String, dynamic> toJson() => {
    'auto_speak': autoSpeak,
    'speech_rate': speechRate,
    'speech_pitch': speechPitch,
    'large_text': largeText,
  };
  static AssistantSettings fromJson(Object? data) {
    if (data is! Map) return defaults;
    bool flag(Object? value, bool fallback) => value is bool ? value : fallback;
    double number(Object? value, double fallback) =>
        value is num ? value.toDouble() : fallback;
    return AssistantSettings(
      autoSpeak: flag(data['auto_speak'], false),
      speechRate: number(data['speech_rate'], 0.5),
      speechPitch: number(data['speech_pitch'], 1.0),
      largeText: flag(data['large_text'], false),
    );
  }
}

abstract class AssistantSettingsStore {
  Future<AssistantSettings> load();
  Future<void> save(AssistantSettings settings);
}

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
    } catch (_) {}
  }
}
