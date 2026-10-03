import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  Future<void> nativeEvent(String name, [Object? arguments]) {
    final processed = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(name, arguments)),
      (_) => processed.complete(),
    );
    return processed.future;
  }

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return 1;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final refused in ['setLanguage', 'setSpeechRate', 'setPitch', 'speak']) {
    test(
      'refused $refused reports failure without waiting for a callback',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == refused ? 0 : 1;
        });
        final speaker = SystemTtsSpeaker();
        try {
          await expectLater(speaker.speak('中文回答'), throwsA(isA<StateError>()));
          expect(calls, contains(refused));
          if (refused != 'speak') expect(calls, isNot(contains('speak')));
        } finally {
          await speaker.dispose();
        }
      },
    );
  }

  test(
    'accepted speech remains pending until completion and forwards progress',
    () async {
      final speaker = SystemTtsSpeaker();
      final progress = <int>[];
      var completed = false;
      final speech = speaker.speak('中文回答', onProgress: progress.add);
      final observed = speech.then((_) => completed = true);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(calls, contains('speak'));
        expect(completed, isFalse);
        await nativeEvent('speak.onProgress', {
          'text': '中文回答',
          'start': 0,
          'end': 2,
          'word': '中文',
        });
        expect(progress, [2]);
        await nativeEvent('speak.onComplete', true);
        await observed;
        expect(completed, isTrue);
      } finally {
        await speaker.dispose();
      }
    },
  );

  test('engine error finishes speech with a fixed error', () async {
    final speaker = SystemTtsSpeaker();
    try {
      final failed = expectLater(
        speaker.speak('中文回答'),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);
      await nativeEvent('speak.onError', 'private engine details');
      await failed;
    } finally {
      await speaker.dispose();
    }
  });

  test('silent engine eventually fails and requests stop', () async {
    final speaker = SystemTtsSpeaker(
      completionTimeout: const Duration(milliseconds: 30),
    );
    try {
      await expectLater(
        speaker.speak('中文回答'),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('speak'));
      expect(calls, contains('stop'));
    } finally {
      await speaker.dispose();
    }
  });

  test('stalled initialization cannot start speech after timing out', () async {
    final language = Completer<int>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'setLanguage' ? language.future : 1;
    });
    final speaker = SystemTtsSpeaker(
      operationTimeout: const Duration(milliseconds: 30),
    );
    try {
      await expectLater(speaker.speak('旧回答'), throwsA(isA<TimeoutException>()));
      language.complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNot(contains('speak')));
    } finally {
      await speaker.dispose();
    }
  });

  test(
    'stop finishes speech even when the platform stop never responds',
    () async {
      final pendingStop = Completer<int>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'stop' ? pendingStop.future : 1;
      });
      final speaker = SystemTtsSpeaker(
        operationTimeout: const Duration(milliseconds: 30),
      );
      final speech = speaker.speak('中文回答');
      await Future<void>.delayed(Duration.zero);
      await speaker.stop();
      await speech;
      pendingStop.complete(1);
      await speaker.dispose();
    },
  );

  test(
    'a late initialization result cannot replace or finish newer speech',
    () async {
      final oldLanguage = Completer<int>();
      var languageCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'setLanguage' && languageCalls++ == 0) {
          return oldLanguage.future;
        }
        return 1;
      });
      final speaker = SystemTtsSpeaker();
      try {
        final oldSpeech = speaker.speak('旧回答');
        await speaker.stop();
        await oldSpeech;
        var completed = false;
        final speech = speaker.speak('新回答');
        final observed = speech.then((_) => completed = true);
        oldLanguage.complete(0);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect(calls.where((method) => method == 'speak'), hasLength(1));
        await nativeEvent('speak.onComplete', true);
        await observed;
      } finally {
        await speaker.dispose();
      }
    },
  );
}
