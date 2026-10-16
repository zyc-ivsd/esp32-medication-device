import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_settings.dart';

void main() {
  test('shipping manifest does not grant network access', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, isNot(contains('android.permission.INTERNET')));
    expect(manifest, contains('android.permission.BLUETOOTH_CONNECT'));
  });

  test('assistant contains no network transports or credential dependencies', () {
    final forbidden = RegExp(
      r'HttpClient|WebSocket|package:http/|package:dio/|flutter_secure_storage',
    );
    for (final file in Directory(
      'lib/assistant',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      expect(
        forbidden.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.path,
      );
    }
  });

  test('old upload preference is ignored while local preferences survive', () {
    final settings = AssistantSettings.fromJson({
      'send_history': true,
      'auto_speak': true,
      'large_text': true,
      'speech_rate': 0.8,
      'speech_pitch': 1.3,
    });
    expect(settings.toJson().containsKey('send_history'), isFalse);
    expect(settings.autoSpeak, isTrue);
    expect(settings.largeText, isTrue);
    expect(settings.speechRate, 0.8);
    expect(settings.speechPitch, 1.3);
  });
}
