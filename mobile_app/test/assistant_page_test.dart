import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_chat_store.dart';
import 'package:medication_device_app/assistant/assistant_credentials.dart';
import 'package:medication_device_app/assistant/assistant_exception.dart';
import 'package:medication_device_app/assistant/assistant_page.dart';
import 'package:medication_device_app/assistant/assistant_provider.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';
import 'package:medication_device_app/assistant/assistant_settings.dart';
import 'package:medication_device_app/assistant/assistant_tts.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/models/chat_message.dart';

/// 内存聊天库：测试不碰平台通道，也方便断言「到底存了什么」。
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

class _MemoryStore implements AssistantCredentialsStore {
  _MemoryStore([this.state = AssistantCredentialState.empty]);

  AssistantCredentialState state;

  @override
  Future<AssistantCredentialState> load() async => state;

  @override
  Future<void> save(AssistantCredentialState next) async => state = next;

  @override
  Future<void> clear() async => state = AssistantCredentialState.empty;
}

/// 固定回答：不联网，专门用来观察界面怎么标注来源。
class _FixedAnswer implements AssistantProvider {
  _FixedAnswer(this.answer);

  final String answer;

  /// 被问了几次：反馈用例据此证明「踩」不会再次调用模型。
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

/// 内存朗读引擎：记录读过的文本与停叫次数，不碰平台通道。
///
/// 真实引擎是**异步结束**的（而且 `FlutterTts.speak` 立刻返回，不能当读完信号用），
/// 所以这里用一个 Completer 挂住：测试自己决定什么时候「读完」，也可以中途回报进度。
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

  /// 模拟引擎回报「已读到第 [endOffset] 个字符」。
  void reportProgress(int endOffset) => _onProgress?.call(endOffset);

  /// 模拟读完（或引擎结束），让 speak 返回的 Future 完成。
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

/// 内存偏好库：测试断言「到底存了什么」。
class _MemorySettingsStore implements AssistantSettingsStore {
  _MemorySettingsStore([this.settings = AssistantSettings.defaults]);

  AssistantSettings settings;

  @override
  Future<AssistantSettings> load() async => settings;

  @override
  Future<void> save(AssistantSettings next) async => settings = next;
}

/// 逐块吐字的在线 provider：专门观察流式回答怎么落成一条消息，以及收到了哪些历史。
class _StreamingProvider implements StreamingAssistantProvider {
  _StreamingProvider(this.chunks, {this.gap = Duration.zero});

  final List<String> chunks;
  final Duration gap;
  List<ChatTurn> lastHistory = const [];

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => chunks.join();

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) async* {
    lastHistory = List.of(history);
    for (final chunk in chunks) {
      if (gap > Duration.zero) await Future<void>.delayed(gap);
      yield chunk;
    }
  }
}

/// 第一次流式请求失败、之后成功：用来验证失败气泡不会被回灌进多轮上下文。
class _FailOnceStreamProvider implements StreamingAssistantProvider {
  int calls = 0;
  List<ChatTurn> lastHistory = const [];

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => '2 uses today.';

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) async* {
    calls++;
    lastHistory = List.of(history);
    if (calls == 1) {
      throw const AssistantException(
        'The model service timed out. Try again or switch to Local.',
      );
    }
    yield '2 uses today.';
  }
}

/// 由测试自己推的在线 provider：吐一块、停住，专门用来观察取消有没有真的传下去。
///
/// 用 `StreamController` 而不是 `async*`：`async*` 被取消时，那个还没到点的
/// `Future.delayed` 计时器会一直挂着，widget 测试结束时框架会报
/// 「A Timer is still pending」。这里完全不挂计时器，取消与否由 [cancelled] 直接反映。
class _ManualStreamProvider implements StreamingAssistantProvider {
  StreamController<String>? _controller;

  /// 订阅被取消过。`StreamController.onCancel` 只在订阅被取消时触发。
  bool cancelled = false;

  /// 推一块内容给页面（订阅还没建立时丢弃）。
  void emit(String chunk) => _controller?.add(chunk);

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => '';

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) {
    final controller = StreamController<String>(
      onCancel: () => cancelled = true,
    );
    _controller = controller;
    return controller.stream;
  }
}

/// 服务端不发结束标记就断流的在线 provider：回答要保留，只在末尾提示「可能不完整」。
class _IncompleteStreamProvider implements StreamingAssistantProvider {
  _IncompleteStreamProvider({this.reason});

  final String? reason;
  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => '2 uses today.';

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) async* {
    yield '2 uses today.';
    // 模拟流正常关闭、但没收到 `data: [DONE]`。
    completion?.markIncomplete(reason);
  }
}

/// 第一次调用失败、之后成功：专门观察「失败 → 重试 → 成功」的入口。
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

/// 延迟回答：专门观察等待中的「取消」——回答迟到后要被丢弃。
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
    // 内容无关紧要：这条用例只关心迟到的回答会被丢弃。
    return '2 uses today.';
  }
}

/// 流式输出中途抛错的在线 provider：观察半截回答不会被落成完整回答。
class _FailMidStreamProvider implements StreamingAssistantProvider {
  List<ChatTurn> lastHistory = const [];
  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => '2 uses today.';

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) async* {
    lastHistory = List.of(history);
    yield '半截回答内容';
    throw const AssistantException('模型回答中途中断，回答未完成，请重试。');
  }
}

const _gateway = AssistantProfile(
  id: 'g1',
  name: 'Team gateway',
  mode: OnlineAssistantMode.gateway,
  endpoint: 'https://assistant.example.com/v1/assistant/chat',
  accessToken: 'gateway-code',
);

const _context = AssistantContext(
  todayCount: 2,
  last7DaysCount: 3,
  totalCount: 9,
  dailyCounts: [0, 1, 0, 0, 1, 0, 1],
);

/// 朗读进度里「还没读到」的那部分用的灰色，与 `assistant_page.dart` 保持一致。
const _unreadGrey = Color(0xff9ca3af);

/// 界面上的九个快捷问题，与 `_AssistantPageState._quickQuestions` 一一对应。
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
  AssistantCredentialsStore? store,
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
  // viewInsets 同样是全局视图状态，框架不会替你还原，必须挂 tearDown。
  // 用例末尾手工还原是有条件的：用例在中途断言失败时那一行根本执行不到，
  // 剩下的用例就全都带着一个「键盘一直按着」的窗口跑——列表被压矮、
  // 懒构建的行不再被建出来，于是报出「状态没丢、却找不到那条消息」的假失败。
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
        store: store,
        chatStore: chats ?? _MemoryChatStore(),
        speaker: speaker,
        settingsStore: settingsStore,
        assistantContext: _context,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 输入并发送一条问题，等回答出现。
Future<void> _ask(WidgetTester tester, String question) async {
  await tester.enterText(find.byType(TextField), question);
  await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
  await tester.pumpAndSettle();
}

/// 摊平一个 [TextSpan] 树，方便断言回答正文里某段数字被上了什么色。
List<TextSpan> _flatten(InlineSpan span) {
  if (span is! TextSpan) return const [];
  return [span, ...span.children?.expand(_flatten) ?? const <TextSpan>[]];
}

void main() {
  testWidgets('键盘弹起时不再溢出，输入的字仍然看得见', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    // 模拟键盘占掉 300 逻辑像素：修复前摘要卡是固定项，会顶出
    // BOTTOM OVERFLOWED BY ... PIXELS，输入框被挤出屏幕。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '键盘测试');
    await tester.pumpAndSettle();
    expect(find.text('键盘测试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 收起键盘，免得影响同一文件里后面的用例。
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
    expect(find.text('Online answer'), findsOneWidget);
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

  testWidgets('通用知识回答标成 AI 知识并补上「不是设备记录」', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _FixedAnswer('哮喘是一种慢性气道炎症。\n【来源】AI知识'),
        isRemote: true,
      ),
    );
    await _ask(tester, '介绍一下哮喘');

    expect(find.text('AI knowledge'), findsOneWidget);
    expect(find.textContaining('not your device records'), findsOneWidget);
    // 标记行本身不显示给用户，来源用小标表达。
    expect(find.textContaining('【来源】'), findsNothing);
  });

  testWidgets('切换本地与在线：历史一条不少，只多一条分隔提示', (tester) async {
    final chats = _MemoryChatStore();
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_gateway], selectedId: 'g1'),
    );
    await _pump(tester, store: store, chats: chats);

    await _ask(tester, 'How many uses today?');
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(find.text('Local answer'), findsOneWidget);
    expect(chats.saved, hasLength(3)); // 开场白 + 提问 + 回答

    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    // 关键：切过去之后本地那条回答还在——这正是以前会整段消失的地方。
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(find.textContaining('Online enabled'), findsOneWidget);
    expect(find.text('Local answer'), findsOneWidget);

    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(
      find.text('Switched to Local. No network connection is used.'),
      findsOneWidget,
    );
    expect(chats.saved, hasLength(5)); // 两次切换各插一条提示
  });

  testWidgets('删除正在使用的模型配置后切回本地，不再调用旧服务', (tester) async {
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_gateway], selectedId: 'g1'),
    );
    await _pump(tester, store: store, size: const Size(800, 1600));

    // 先切到在线（用 gateway 这条）。
    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Online enabled'), findsOneWidget);
    expect(
      find.textContaining(
        'Raw records, device identifiers and chat history are not sent',
      ),
      findsOneWidget,
    );

    // 打开管理 API，删掉正在用的这条。
    await tester.tap(find.byTooltip('Manage APIs'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete API'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // 删除后应立即切回本地，不再用旧 Key。
    expect(
      find.textContaining('The selected model configuration was deleted'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Raw records, device identifiers and chat history are not sent',
      ),
      findsNothing,
    );
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
    // 视口给足高度：列表是懒构建的，滚出视口（连同 250 逻辑像素的缓存区）的
    // 行压根不会被建出来。这条用例问的是「取消后对话还在不在」，不该顺带
    // 依赖滚动位置，否则它在「回答恰好很长」时会给出误导性的红。
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

    // 等待期间清空：用显式时长推进菜单/对话框动画，不用 pumpAndSettle——
    // 它会一直推着思考气泡里的转圈动画往前走，还会顺带把慢回答的计时器也触发。
    //
    // 每一步必须先 pump 一帧、再按时长推进：插入路由那一帧动画才开始，只 pump
    // 一次时长等于让它从 0 走起，菜单还没画完就点，命中的会是模态遮罩而不是
    // 菜单项（日志里表现为 NEEDS-PAINT + 命中 ModalBarrier，随后找不到「清空」）。
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

    // 让慢回答计时器到点：代次已变，迟到回答被丢弃。
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
    expect(find.text('Include this session'), findsOneWidget);
    expect(find.text('Read-aloud settings'), findsOneWidget);
    expect(find.text('Larger text'), findsOneWidget);
    // 外观切换（跟随系统 / 浅色 / 深色）已按需求移除。前面正数断言先保证
    // 菜单真的展开了，这一条才有意义（单写 findsNothing 在菜单根本没开时也会通过）。
    expect(find.textContaining('外观：'), findsNothing);
  });

  testWidgets('快捷问题每个都能在本地拿到答案，不落到兜底', (tester) async {
    await _pump(tester);
    expect(find.byType(ActionChip), findsNWidgets(_quickQuestions.length));

    for (final question in _quickQuestions) {
      final chip = find.widgetWithText(ActionChip, question);
      // 后面的问题是横向滚出去的，先滚进视口再点。
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

    // 开场白和回答都是助手气泡，各带一个「朗读」；取最后一个 = 最新回答。
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
    // 读的过程中那一条变成「停止」，另一个气泡（开场白）不受影响。
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Read aloud'), findsOneWidget);

    // 提问开始、开始朗读各已经停过一次了，这里只断言「这一次又停了一次」。
    final stopsBefore = speaker.stops;
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(speaker.stops, stopsBefore + 1);
    // 停完回到「朗读」，可以再点。
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

    // _flatten 会把最外层那个「只有 children、没有 text」的根节点也带出来，
    // 断言片段文本之前先滤掉它（原测试用 text == '2' 过滤，天然躲过了这一层）。
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

    // 还没开始读（引擎也还没回报进度）：整段都是正常样式。
    expect(
      answerSpans().every((span) => span.style?.color != _unreadGrey),
      isTrue,
    );

    // 引擎回报「已读到第 4 个字符」：前 4 个字（「近 7 」）是已读，后面变灰。
    speaker.reportProgress(4);
    await tester.pump();
    final spans = answerSpans();

    // 正文会被数字切成多段（「近 7 天共 3 次。」→ 近 / 7 / 天共 / 3 / 次。），
    // 所以不按下标断言，改成「已读的拼起来 / 变灰的拼起来」分别是哪一段。
    String joinedWhere({required bool greyed}) => spans
        .where((span) => (span.style?.color == _unreadGrey) == greyed)
        .map((span) => span.text!)
        .join();
    expect(joinedWhere(greyed: false), '近 7 ');
    expect(joinedWhere(greyed: true), '天共 3 次。');

    // 还没读到的数字也不该保留数据蓝：没读到就不该看起来像已经读过了。
    expect(
      spans.where((span) => span.text == '3').single.style?.color,
      _unreadGrey,
    );
  });

  testWidgets('在线流式回答逐字滚出，结束后落成带来源标的回答', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _StreamingProvider([
          '近 7 天共 ',
          '3 次使用动作。',
        ], gap: const Duration(milliseconds: 100)),
        isRemote: true,
      ),
    );
    await tester.enterText(find.byType(TextField), '最近怎么样');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    // 第一块已到、流还没结束：能看到滚动的部分文本和「正在输出」。
    expect(find.text('Generating'), findsOneWidget);
    expect(find.textContaining('近 7 天共'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.textContaining('近 7 天共 3 次使用动作。'), findsOneWidget);
    expect(find.text('Online answer'), findsOneWidget);
    expect(find.text('Generating'), findsNothing);
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
    // 提问开始与朗读开始各会停一次上一段，保证「只读最新一句」。
    expect(speaker.stops, greaterThanOrEqualTo(1));
  });

  testWidgets('「带上本轮对话」开关落盘，开启后流式请求带上历史', (tester) async {
    final settings = _MemorySettingsStore();
    final provider = _StreamingProvider(['近 7 天共 3 次。']);
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      settingsStore: settings,
    );

    // 默认关：第一问不带历史。
    await _ask(tester, 'Any invalid uses recently?');
    expect(provider.lastHistory, isEmpty);
    expect(settings.settings.sendHistory, isFalse);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include this session'));
    await tester.pumpAndSettle();
    expect(settings.settings.sendHistory, isTrue);

    // 再问一条，应把上一轮问答带出去。
    await _ask(tester, '那今天呢？');
    expect(provider.lastHistory, isNotEmpty);
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
    // 搜索条在输入栏之前构建，是第一个 TextField。
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
    // 追问用 InputChip，不与底部固定的 ActionChip 快捷问题混在一起。
    expect(find.byType(InputChip), findsNWidgets(3));
  });

  testWidgets('摘要卡显示同步状态徽章', (tester) async {
    await _pump(tester);
    // 默认 context 无同步时间 → 「尚未同步」。
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

  testWidgets('踩在线回答会在本地重新解释，不回传反馈', (tester) async {
    final provider = _FixedAnswer('本周记录了 12 次。');
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      size: const Size(420, 1400),
    );
    await _ask(tester, 'How many uses today?');
    expect(provider.calls, 1);

    await tester.tap(find.byTooltip('Not helpful').last);
    await tester.pumpAndSettle();

    // 反馈只落在本地界面：在线 provider 没被再问一次，也不会把反馈发给模型。
    expect(provider.calls, 1);
    expect(find.textContaining('Feedback saved on this phone'), findsOneWidget);
    expect(find.text('Local answer'), findsOneWidget);
    expect(find.textContaining('2 uses today'), findsOneWidget);
  });

  testWidgets('回答失败后给重试入口，点重试能成功', (tester) async {
    final provider = _FailOnceProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
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

    // 等迟到回答返回：代次已变，结果被丢弃，不落成回答。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 uses today'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('流式回答时可点「停止」，未完成的输出不落成回答', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _StreamingProvider([
          '近 7 天共 ',
          '3 次使用动作。',
          '2 uses today.',
        ], gap: const Duration(milliseconds: 200)),
        isRemote: true,
      ),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), '最近怎么样');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // 第一块已到、流还在走：能看到部分文本和「停止」。
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('近 7 天共'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Question cancelled.'), findsOneWidget);

    // 让剩余 chunk 计时器走完，确认被丢弃、不落成带来源标的完整回答。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Online answer'), findsNothing);
    expect(find.textContaining('2 uses today.'), findsNothing);
  });

  testWidgets('流式中途报错保留正文，存为未完成且不自动朗读', (tester) async {
    final chats = _MemoryChatStore();
    final speaker = _MemorySpeaker();
    await _pump(
      tester,
      chats: chats,
      speaker: speaker,
      settingsStore: _MemorySettingsStore(
        const AssistantSettings(autoSpeak: true),
      ),
      service: AssistantService(
        provider: _FailMidStreamProvider(),
        isRemote: true,
      ),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), '最近怎么样');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('incomplete'), findsOneWidget);
    expect(
      find.text('The last request failed. Tap to try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('半截回答内容'), findsOneWidget);
    final partial = chats.saved.singleWhere((m) => m.text.contains('半截回答内容'));
    expect(partial.isIncomplete, isTrue);
    expect(partial.text, contains('incomplete'));
    expect(speaker.spoken, isEmpty);
  });

  testWidgets('保留的半截回答不会回灌到下一轮模型上下文', (tester) async {
    final provider = _FailMidStreamProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      settingsStore: _MemorySettingsStore(
        const AssistantSettings(sendHistory: true),
      ),
      size: const Size(420, 1400),
    );
    await _ask(tester, 'How many uses today?');
    await _ask(tester, '那昨天呢？');
    expect(provider.lastHistory, isNotEmpty);
    expect(
      provider.lastHistory.every((turn) => !turn.text.contains('半截回答内容')),
      isTrue,
    );
  });

  testWidgets('点「停止」会真的取消订阅，而不是等下一个 chunk 才发现', (tester) async {
    final provider = _ManualStreamProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), '最近怎么样');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump();
    provider.emit('近 7 天共 ');
    await tester.pump();
    // 先证明订阅确实建好了、事件收得到，否则「没取消」这个断言毫无意义。
    expect(find.textContaining('近 7 天共'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(provider.cancelled, isFalse);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    await tester.pump();
    // 订阅已经取消：底层请求据此掐断，模型不会继续生成、继续计费。
    expect(provider.cancelled, isTrue);
  });

  testWidgets('清空对话也会取消订阅，在跑的请求不再继续', (tester) async {
    final provider = _ManualStreamProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), '最近怎么样');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pump();
    await tester.pump();
    provider.emit('近 7 天共 ');
    await tester.pump();
    expect(find.textContaining('近 7 天共'), findsOneWidget);

    // 流还在，先取消订阅才叫「停下来」；用显式时长推进菜单/对话框动画，
    // 不能用 pumpAndSettle——它会一直推着思考气泡里的转圈动画往前走。
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

    expect(provider.cancelled, isTrue);
  });

  testWidgets('流没收结束标记：回答照给，末尾提示可能不完整', (tester) async {
    await _pump(
      tester,
      service: AssistantService(
        provider: _IncompleteStreamProvider(),
        isRemote: true,
      ),
      size: const Size(420, 1400),
    );
    await tester.enterText(find.byType(TextField), 'How many uses today?');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle();

    // 不发 [DONE] 的服务端不算少见，内容往往是全的：不丢回答。
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(find.text('Online answer'), findsOneWidget);
    // 但也没法确认收全了，得如实提醒。
    expect(find.textContaining('may be incomplete'), findsOneWidget);
    // 提示归提示，重试入口不出现——这次不算失败。
    expect(
      find.text('The last request failed. Tap to try again.'),
      findsNothing,
    );
  });

  testWidgets('失败提示不会被当成历史回灌给模型', (tester) async {
    final provider = _FailOnceStreamProvider();
    await _pump(
      tester,
      service: AssistantService(provider: provider, isRemote: true),
      settingsStore: _MemorySettingsStore(
        const AssistantSettings(sendHistory: true),
      ),
      size: const Size(420, 1400),
    );

    // 第一问失败，留下一条失败气泡。
    await _ask(tester, 'How many uses today?');
    expect(provider.calls, 1);
    expect(find.textContaining('The model service timed out'), findsOneWidget);

    // 第二问带上本轮对话，失败气泡不能被当成「助手说过的话」发出去。
    await _ask(tester, '那昨天呢？');
    expect(provider.calls, 2);
    expect(provider.lastHistory, isNotEmpty);
    expect(
      provider.lastHistory.every((turn) => !turn.text.contains('timed out')),
      isTrue,
      reason: '失败提示是 App 写的，不是模型的回答，不该进多轮上下文',
    );
    expect(
      provider.lastHistory.any(
        (turn) => turn.text.contains('How many uses today'),
      ),
      isTrue,
    );
  });

  testWidgets('模型输出截断时保留回答，并显示明确原因与重试入口', (tester) async {
    final chats = _MemoryChatStore();
    await _pump(
      tester,
      chats: chats,
      service: AssistantService(
        provider: _IncompleteStreamProvider(
          reason:
              'The model reached its output limit. The answer is incomplete; ask in smaller parts or retry.',
        ),
        isRemote: true,
      ),
      size: const Size(420, 1400),
    );
    await _ask(tester, 'How many uses today?');
    expect(find.textContaining('2 uses today'), findsOneWidget);
    expect(find.textContaining('output limit'), findsOneWidget);
    expect(
      find.text('The last request failed. Tap to try again.'),
      findsOneWidget,
    );
    expect(
      chats.saved
          .singleWhere((m) => m.text.contains('output limit'))
          .isIncomplete,
      isTrue,
    );
  });
}
