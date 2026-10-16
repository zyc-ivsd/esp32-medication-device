import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_chat_store.dart';
import 'package:medication_device_app/assistant/assistant_exception.dart';
import 'package:medication_device_app/assistant/assistant_page.dart';
import 'package:medication_device_app/assistant/assistant_provider.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';
import 'package:medication_device_app/assistant/assistant_settings.dart';
import 'package:medication_device_app/assistant/assistant_tts.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/models/chat_message.dart';

class _MemoryChatStore implements AssistantChatStore {
  _MemoryChatStore([this.saved = const []]);

  List<ChatMessage> saved;
  int clears = 0;

  @override
  Future<List<ChatMessage>> load() async => saved;

  @override
  Future<void> save(List<ChatMessage> messages) async =>
      saved = List.of(messages);

  @override
  Future<void> clear() async {
    clears++;
    saved = const [];
  }
}

class _FixedAnswer implements AssistantProvider {
  _FixedAnswer(this.answer);

  final String answer;
  int calls = 0;

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    calls++;
    return answer;
  }
}

class _MemorySpeaker implements AssistantSpeaker {
  final spoken = <String>[];
  int stops = 0;

  void Function(int endOffset)? _onProgress;
  Completer<void>? _pending;

  @override
  Future<void> speak(String text, {void Function(int endOffset)? onProgress}) {
    spoken.add(text);
    _onProgress = onProgress;
    final done = Completer<void>();
    _pending = done;
    return done.future;
  }

  void reportProgress(int endOffset) => _onProgress?.call(endOffset);
  void finish() {
    final done = _pending;
    _pending = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> dispose() async {}
}

class _MemorySettingsStore implements AssistantSettingsStore {
  _MemorySettingsStore([this.settings = AssistantSettings.defaults]);

  AssistantSettings settings;

  @override
  Future<AssistantSettings> load() async => settings;

  @override
  Future<void> save(AssistantSettings next) async => settings = next;
}

class _FailOnceProvider implements AssistantProvider {
  int calls = 0;

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    calls++;
    if (calls == 1) {
      throw const AssistantException(
        'The model service timed out. Try again or switch to Local.',
      );
    }
    return '2 uses today.';
  }
}

class _SlowAnswer implements AssistantProvider {
  _SlowAnswer(this.delay);

  final Duration delay;

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    await Future<void>.delayed(delay);
    return '2 uses today.';
  }
}

const _context = AssistantContext(
  todayCount: 2,
  last7DaysCount: 3,
  totalCount: 9,
  dailyCounts: [0, 1, 0, 0, 1, 0, 1],
);
const _unreadGrey = Color(0xff9ca3af);
const _quickQuestions = [
  'How many uses today?',
  'Any invalid uses recently?',
  'Show the last week',
  'What needs attention?',
  'Is my data up to date?',
  'Is the device clock correct?',
  'How many records are saved?',
  'What do days without records mean?',
  'What can I ask?',
];

Future<void> _pump(
  WidgetTester tester, {
  AssistantService? service,
  AssistantChatStore? chats,
  AssistantSpeaker? speaker,
  AssistantSettingsStore? settingsStore,
  Size size = const Size(420, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.view.viewInsets = const FakeViewPadding());
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AssistantPage(
        service: service,
        chatStore: chats ?? _MemoryChatStore(),
        speaker: speaker,
        settingsStore: settingsStore,
        assistantContext: _context,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _ask(WidgetTester tester, String question) async {
  await tester.enterText(find.byType(TextField), question);
  await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
  await tester.pumpAndSettle();
}

List<TextSpan> _flatten(InlineSpan span) {
  if (span is! TextSpan) return const [];
  return [span, ...span.children?.expand(_flatten) ?? const <TextSpan>[]];
}

void main() {
  testWidgets('offline assistant has no cloud controls and answers locally', (
    tester,
  ) async {
    await _pump(tester, size: const Size(420, 1400));
    expect(
      find.text('Offline assistant · Your records stay on this phone'),
      findsOneWidget,
    );
    expect(find.text('Online'), findsNothing);
    expect(find.byTooltip('Manage APIs'), findsNothing);
    await _ask(tester, 'How many uses today?');
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(find.text('Local answer'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Include this session'), findsNothing);
  });

  testWidgets('键盘弹起时不再溢出，输入的字仍然看得见', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '键盘测试');
    await tester.pumpAndSettle();
    expect(find.text('键盘测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
  });

  testWidgets('大字号加键盘同时出现也不溢出', (tester) async {
    await _pump(tester, size: const Size(375, 812), textScale: 1.5);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
  });

  testWidgets('重新打开时读回本机历史，而不是从开场白开始', (tester) async {
    final chats = _MemoryChatStore([
      ChatMessage(
        role: ChatRole.user,
        text: '昨天问过的问题',
        createdAt: DateTime(2026, 9, 28),
      ),
      ChatMessage(
        role: ChatRole.assistant,
        text: '昨天得到的回答',
        createdAt: DateTime(2026, 9, 28),
        source: ChatSource.online,
      ),
    ]);

    await _pump(tester, chats: chats);

    expect(find.text('昨天问过的问题'), findsOneWidget);
    expect(find.text('昨天得到的回答'), findsOneWidget);
    expect(find.text('Archived online answer'), findsOneWidget);
  });

  testWidgets('本地回答与在线回答各自带来源标', (tester) async {
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('近 7 天共 3 次。')),
    );
    await _ask(tester, 'Any invalid uses recently?');
    expect(find.text('Local answer'), findsOneWidget);
    expect(find.textContaining('近 7 天共 3 次。'), findsOneWidget);
  });

  testWidgets('清空对话会删掉本机历史，只留开场白', (tester) async {
    final chats = _MemoryChatStore();
    await _pump(tester, chats: chats);
    await _ask(tester, '随便问问');
    expect(chats.saved, hasLength(3));

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(chats.clears, 1);
    expect(chats.saved, hasLength(1));
    expect(find.textContaining('随便问问'), findsNothing);
  });

  testWidgets('取消清空时什么都不动', (tester) async {
    final chats = _MemoryChatStore();
    await _pump(tester, chats: chats, size: const Size(420, 1400));
    await _ask(tester, '随便问问');

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(chats.clears, 0);
    expect(chats.saved, hasLength(3));
    expect(find.textContaining('随便问问'), findsOneWidget);
  });

  testWidgets('清空聊天会让还在路上的回答失效，不再冒出来', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _SlowAnswer(const Duration(seconds: 3)),
      ),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), 'How many uses today?');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cancel'), findsOneWidget);
    Future<void> advanceOverlays() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tester.tap(find.byTooltip('More'));
    await advanceOverlays();
    await tester.tap(find.text('Clear chat'));
    await advanceOverlays();
    await tester.tap(find.text('Clear'));
    await advanceOverlays();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.textContaining('2 uses today'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('「更多」菜单有对话、朗读与大字三项，不再有外观切换', (tester) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Clear chat'), findsOneWidget);
    expect(find.text('Include this session'), findsNothing);
    expect(find.text('Read-aloud settings'), findsOneWidget);
    expect(find.text('Larger text'), findsOneWidget);
    expect(find.textContaining('外观：'), findsNothing);
  });

  testWidgets('快捷问题每个都能在本地拿到答案，不落到兜底', (tester) async {
    await _pump(tester);
    expect(find.byType(ActionChip), findsNWidgets(_quickQuestions.length));

    for (final question in _quickQuestions) {
      final chip = find.widgetWithText(ActionChip, question);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Local uses fixed rules to explain saved records'),
        findsNothing,
        reason: '「$question」落到了兜底，说明没有对应的规则分支',
      );
    }
  });

  testWidgets('助手回答可以朗读，读的是回答正文', (tester) async {
    final speaker = _MemorySpeaker();
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('近 7 天共 3 次。')),
      speaker: speaker,
    );
    await _ask(tester, 'Any invalid uses recently?');
    await tester.tap(find.text('Read aloud').last);
    await tester.pumpAndSettle();
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.first, contains('近 7 天共 3 次'));
  });

  testWidgets('朗读中那条回答的按钮变「停止」，再点一次就停', (tester) async {
    final speaker = _MemorySpeaker();
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('近 7 天共 3 次。')),
      speaker: speaker,
    );
    await _ask(tester, 'Any invalid uses recently?');

    await tester.tap(find.text('Read aloud').last);
    await tester.pump();
    expect(speaker.spoken, hasLength(1));
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Read aloud'), findsOneWidget);
    final stopsBefore = speaker.stops;
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(speaker.stops, stopsBefore + 1);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Read aloud'), findsNWidgets(2));
  });

  testWidgets('朗读时已读部分保持原样式，未读部分变灰', (tester) async {
    final speaker = _MemorySpeaker();
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('近 7 天共 3 次。')),
      speaker: speaker,
    );
    await _ask(tester, 'Any invalid uses recently?');
    await tester.tap(find.text('Read aloud').last);
    await tester.pump();
    List<TextSpan> answerSpans() => _flatten(
      tester
          .widgetList<Text>(
            find.byWidgetPredicate(
              (widget) => widget is Text && widget.textSpan != null,
            ),
          )
          .firstWhere(
            (widget) => widget.textSpan!.toPlainText().contains('近 7 天共 3 次'),
          )
          .textSpan!,
    ).where((span) => span.text != null).toList();
    expect(
      answerSpans().every((span) => span.style?.color != _unreadGrey),
      isTrue,
    );
    speaker.reportProgress(4);
    await tester.pump();
    final spans = answerSpans();
    String joinedWhere({required bool greyed}) => spans
        .where((span) => (span.style?.color == _unreadGrey) == greyed)
        .map((span) => span.text!)
        .join();
    expect(joinedWhere(greyed: false), '近 7 ');
    expect(joinedWhere(greyed: true), '天共 3 次。');
    expect(
      spans.where((span) => span.text == '3').single.style?.color,
      _unreadGrey,
    );
  });

  testWidgets('开启自动朗读后新回答自动朗读，新问题会先停掉上一段', (tester) async {
    final speaker = _MemorySpeaker();
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('近 7 天共 3 次。')),
      speaker: speaker,
      settingsStore: _MemorySettingsStore(
        const AssistantSettings(autoSpeak: true),
      ),
    );
    await _ask(tester, 'Any invalid uses recently?');
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.first, contains('近 7 天共 3 次'));
    expect(speaker.stops, greaterThanOrEqualTo(1));
  });

  testWidgets('「大字模式」开关落盘', (tester) async {
    final settings = _MemorySettingsStore();
    await _pump(tester, settingsStore: settings);
    expect(settings.settings.largeText, isFalse);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Larger text'));
    await tester.pumpAndSettle();
    expect(settings.settings.largeText, isTrue);
  });

  testWidgets('大字模式下小视口也不溢出', (tester) async {
    await _pump(
      tester,
      settingsStore: _MemorySettingsStore(
        const AssistantSettings(largeText: true),
      ),
      size: const Size(375, 812),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索对话能按正文过滤历史', (tester) async {
    final chats = _MemoryChatStore([
      ChatMessage(
        role: ChatRole.user,
        text: '昨天问过的问题',
        createdAt: DateTime(2026, 9, 28),
      ),
      ChatMessage(
        role: ChatRole.assistant,
        text: '昨天得到的回答',
        createdAt: DateTime(2026, 9, 28),
        source: ChatSource.online,
      ),
    ]);
    await _pump(tester, chats: chats);
    expect(find.text('昨天问过的问题'), findsOneWidget);

    await tester.tap(find.byTooltip('Search chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '回答');
    await tester.pumpAndSettle();

    expect(find.text('昨天问过的问题'), findsNothing);
    expect(find.text('昨天得到的回答'), findsOneWidget);
  });

  testWidgets('答完后给出「接着问」追问', (tester) async {
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('2 uses today.')),
    );
    await _ask(tester, 'How many uses today?');

    expect(find.text('Ask a follow-up'), findsOneWidget);
    expect(find.byType(InputChip), findsNWidgets(3));
  });

  testWidgets('摘要卡显示同步状态徽章', (tester) async {
    await _pump(tester);
    expect(find.text('Not synced yet'), findsOneWidget);
  });

  testWidgets('回答正文里个人数据数字标蓝', (tester) async {
    await _pump(
      tester,
      service: AssistantService(provider: _FixedAnswer('2 uses today.')),
    );
    await _ask(tester, 'How many uses today?');

    final answerText = tester
        .widgetList<Text>(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.textSpan != null,
          ),
        )
        .firstWhere(
          (text) => text.textSpan!.toPlainText().contains('2 uses today'),
        );

    final data = _flatten(
      answerText.textSpan!,
    ).where((s) => s.text == '2').single;
    expect(data.style?.color, const Color(0xff75518c));
  });

  testWidgets('回答失败后给重试入口，点重试能成功', (tester) async {
    final provider = _FailOnceProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider),
      size: const Size(420, 1400),
    );
    await _ask(tester, 'How many uses today?');

    expect(provider.calls, 1);
    expect(find.textContaining('The model service timed out'), findsOneWidget);
    expect(
      find.text('The last request failed. Tap to try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('The last request failed. Tap to try again.'));
    await tester.pumpAndSettle();

    expect(provider.calls, 2);
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(
      find.text('The last request failed. Tap to try again.'),
      findsNothing,
    );
  });

  testWidgets('等待回答时可点「取消」，迟到结果被丢弃', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _SlowAnswer(const Duration(milliseconds: 500)),
      ),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), 'How many uses today?');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Question cancelled.'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 uses today'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });
}
