import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'assistant_api_console.dart';
import 'assistant_chat_store.dart';
import 'assistant_credentials.dart';
import 'assistant_service.dart';
import 'assistant_settings.dart';
import 'assistant_exception.dart';
import 'assistant_tts.dart';
import 'answer_styling.dart';
import 'follow_up_suggestions.dart';
import 'sync_status.dart';
import 'models/assistant_context.dart';
import 'models/chat_message.dart';

/// 本地与在线两种上游的识别色。全页的强调色只有这两枚，换配色只改这里。
///
/// 在线用靛蓝而不是另一档青绿：这两个颜色在一屏里会同时出现（分段控件、
/// 来源小标、发送按钮），色相差距太小就等于没区分。
const _localAccent = Color(0xff147d79);
const _onlineAccent = Color(0xff4f6bd9);

class AssistantPage extends StatefulWidget {
  const AssistantPage({
    super.key,
    this.service,
    this.assistantContext = const AssistantContext(),
    this.contextLoader,
    this.store,
    this.chatStore,
    this.speaker,
    this.settingsStore,
  });

  final AssistantService? service;
  final AssistantContext assistantContext;
  final Future<AssistantContext> Function()? contextLoader;

  /// 已保存的在线 API。测试注入用；默认走系统安全存储。
  final AssistantCredentialsStore? store;

  /// 聊天记录存储。测试注入内存实现；默认写本机偏好存储。
  final AssistantChatStore? chatStore;

  /// 朗读回答用的引擎。测试注入假实现；默认用手机的 Android 系统 TTS。
  final AssistantSpeaker? speaker;

  /// 朗读与多轮偏好的存储。测试注入内存实现；默认写本机偏好存储。
  final AssistantSettingsStore? settingsStore;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  late AssistantService _service;
  late final AssistantCredentialsStore _store;
  late final AssistantChatStore _chatStore;
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  late final List<ChatMessage> _messages;
  bool _sending = false;
  late AssistantContext _context;

  /// 只在第一次点「朗读」时才创建系统 TTS，避免测试/未用到时碰平台通道。
  AssistantSpeaker? _speaker;
  bool _ownsSpeaker = false;

  late final AssistantSettingsStore _settingsStore;

  /// 多轮对话开关：默认关。开启后只有「我的模型」直连时才把本轮更早问答带出去。
  bool _sendHistory = false;

  /// 回答后自动朗读开关：默认关。
  bool _autoSpeak = false;

  /// 朗读语速/音调，取值与 flutter_tts 一致（0–1 / 0.5–2）。
  double _speechRate = 0.5;
  double _speechPitch = 1.0;

  /// 在线流式回答进行中；此时显示逐字滚动的文本而不是「正在询问…」。
  bool _streaming = false;
  String _streamText = '';

  /// 对话搜索：开关 + 查询词。
  bool _searching = false;
  String _searchQuery = '';

  /// 大字模式（默认关）。开启后整页字号放大一档。
  bool _largeText = false;

  /// 最近一次失败的提问，用于回答失败后给「重试」入口。
  String? _failedQuestion;

  /// 请求代次：每次发送 +1；「取消」也 +1。异步结果回来时对不上代次就丢弃，
  /// 这样用户点了取消后，迟到的回答或错误不会再冒出来。
  int _requestGeneration = 0;

  /// 当前在线服务对应的是哪条档案的 id。删除/编辑配置后据此判断要不要
  /// 切回本地或重建服务（见 [_reconcileAfterConsole]）。
  String? _onlineProfileId;

  /// 中止当前流式订阅的入口，流结束后置空。
  ///
  /// 光把 [_requestGeneration] 加一只能让迟到的结果作废，请求本身还在跑；调用这个
  /// 才会真的取消订阅、进而掐断底层连接（见 `StreamingAssistantProvider` 的约定）。
  Future<void> Function()? _abortStream;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AssistantService();
    _store = widget.store ?? SecureAssistantCredentialsStore();
    _chatStore = widget.chatStore ?? SharedPreferencesAssistantChatStore();
    _settingsStore =
        widget.settingsStore ?? SharedPreferencesAssistantSettingsStore();
    _context = widget.assistantContext;
    _inputController = TextEditingController();
    _scrollController = ScrollController();
    _messages = [_welcomeMessage()];
    unawaited(_loadHistory());
    unawaited(_loadSettings());
  }

  @override
  void dispose() {
    // 离开页面也要停掉在跑的请求，否则它会在后台跑完、白花钱。
    unawaited(_abortStream?.call() ?? Future<void>.value());
    if (_ownsSpeaker) unawaited(_speaker?.dispose());
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 拿到本次要用的朗读引擎：注入的优先，否则第一次用时新建系统 TTS。
  AssistantSpeaker get _resolvedSpeaker {
    final injected = widget.speaker;
    if (injected != null) return injected;
    final existing = _speaker;
    if (existing != null) return existing;
    final created = SystemTtsSpeaker();
    _speaker = created;
    _ownsSpeaker = true;
    return created;
  }

  /// 正在朗读的那条回答，以及已读到的字符数（未读部分在正文里显示成灰色）。
  ///
  /// 存消息对象而不是下标：列表里的消息会因为反馈被替换成副本，下标不稳。
  ChatMessage? _speakingMessage;
  int _spokenChars = 0;

  /// 每次开始朗读 +1。迟到的进度/结束回调带着旧代号，直接丢掉，
  /// 免得上一段的进度盖到刚开的那一段上。
  int _speechGeneration = 0;

  /// 朗读一条回答；同一条正在读时再点一次就是停止（按钮会变成「停止」）。
  Future<void> _speak(ChatMessage message) async {
    if (identical(_speakingMessage, message)) {
      await _stopSpeaking();
      return;
    }
    final generation = ++_speechGeneration;
    // 只读最新一句：先停掉上一段，但**不**把界面收回「朗读」——紧接着就要播新的。
    await _stopSpeakerOnly();
    if (!mounted || generation != _speechGeneration) return;
    setState(() {
      _speakingMessage = message;
      _spokenChars = 0;
    });
    try {
      final speaker = _resolvedSpeaker;
      await speaker.setRate(_speechRate);
      await speaker.setPitch(_speechPitch);
      await speaker.speak(
        message.text,
        onProgress: (endOffset) {
          // 引擎按「已读到第几个字符」回报；过期的那一段直接忽略。
          if (!mounted || generation != _speechGeneration) return;
          if (endOffset == _spokenChars) return;
          setState(() => _spokenChars = endOffset);
        },
      );
    } catch (_) {
      // 引擎缺失/初始化失败是设备差异，不是错误路径里要回显的东西；
      // 只给一句固定提示，不让用户以为按了没反应。
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('此设备暂不支持朗读。')));
      }
    } finally {
      // 读完、出错或被停：收回「停止」。期间若又开了新的一段（代号变了），
      // 就不要动它的状态。
      if (mounted && generation == _speechGeneration) {
        setState(() {
          _speakingMessage = null;
          _spokenChars = 0;
        });
      }
    }
  }

  /// 已经创建的朗读引擎；没有就返回 null（注入的优先）。
  AssistantSpeaker? get _existingSpeaker => widget.speaker ?? _speaker;

  /// 只停引擎，不动界面状态（开始读新一段前用，界面紧接着要换成新的一段）。
  Future<void> _stopSpeakerOnly() async {
    final speaker = _existingSpeaker;
    if (speaker == null) return;
    try {
      await speaker.stop();
    } catch (_) {
      // 引擎报错不影响提问流程。
    }
  }

  /// 用户点「停止」（以及清空对话）时用：停引擎并把界面收回「朗读」。
  ///
  /// 没有引擎时不创建——别为「停一下」碰平台通道。
  Future<void> _stopSpeaking() async {
    _speechGeneration++;
    if (mounted) {
      setState(() {
        _speakingMessage = null;
        _spokenChars = 0;
      });
    }
    await _stopSpeakerOnly();
  }

  /// 开了自动朗读就播最新回答；不 await，别让朗读卡住界面。
  void _maybeAutoSpeak(ChatMessage message) {
    if (!_autoSpeak || message.isIncomplete || message.isError) return;
    unawaited(_speak(message));
  }

  /// 开场白是 App 自己写的，不带来源标（它不是哪个上游的回答）。
  ChatMessage _welcomeMessage() => ChatMessage(
    role: ChatRole.assistant,
    text:
        '你好，我可以解释${_context.isDemo ? '演示数据' : '本地设备记录'}的统计。'
        '${_service.isRemote ? '当前使用在线助手。' : '当前使用本地规则回答，不联网。'}'
        '记录的动作次数不代表确认服药。',
    createdAt: DateTime.now(),
  );

  /// 读本机历史。读不到、或本来就空，就保留开场白。
  Future<void> _loadHistory() async {
    final history = await _chatStore.load();
    if (!mounted || history.isEmpty) return;
    // 读盘期间用户可能已经提问了，那种情况下不能把刚发的消息覆盖掉。
    if (_messages.length > 1) return;
    setState(() => _messages
      ..clear()
      ..addAll(history));
    _scrollToBottom();
  }

  /// 每次消息变动后落盘。
  ///
  /// 故意不 await：写失败也只是这次没存上（见 [AssistantChatStore] 的失败语义），
  /// 不该让发送流程等磁盘。
  /// 读本机偏好。读不到就用默认值（多轮关、自动朗读关、正常语速/音调）。
  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;
    setState(() {
      _sendHistory = settings.sendHistory;
      _autoSpeak = settings.autoSpeak;
      _speechRate = settings.speechRate;
      _speechPitch = settings.speechPitch;
      _largeText = settings.largeText;
    });
  }

  void _persistHistory() => unawaited(_chatStore.save(List.of(_messages)));

  /// 偏好落盘。故意不 await：写失败也只影响下次打开，不该打断当前对话。
  void _persistSettings() => unawaited(
    _settingsStore.save(
      AssistantSettings(
        sendHistory: _sendHistory,
        autoSpeak: _autoSpeak,
        speechRate: _speechRate,
        speechPitch: _speechPitch,
        largeText: _largeText,
      ),
    ),
  );

  Future<void> _send([String? preset]) async {
    final question = (preset ?? _inputController.text).trim();
    if (question.isEmpty || _sending) return;

    // 新问题先停掉上一段朗读：正在读的旧回答不该盖过新问题。
    await _stopSpeaking();

    _inputController.clear();
    // 新问题来了，清掉上一次的失败标记。
    _failedQuestion = null;
    // 多轮上下文只取「本轮更早的」消息：先快照，再追加新提问。
    final history = _sendHistory ? List.of(_messages) : const <ChatMessage>[];
    final generation = ++_requestGeneration;
    setState(() {
      _messages.add(
        ChatMessage(
          role: ChatRole.user,
          text: question,
          createdAt: DateTime.now(),
        ),
      );
      _sending = true;
      _streaming = false;
      _streamText = '';
    });
    _persistHistory();
    _scrollToBottom();

    // 回答是提问那一刻的上游给出的：等待期间用户可能切了模式，
    // 失败气泡的来源要按切换前算，否则会标错。
    final wasRemote = _service.isRemote;

    try {
      final latestContext =
          await widget.contextLoader?.call() ?? widget.assistantContext;
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _context = latestContext);

      if (wasRemote && _service.supportsStreaming) {
        await _streamAnswer(
          question,
          latestContext,
          history,
          generation: generation,
        );
      } else {
        final answer = await _service.ask(
          question: question,
          context: latestContext,
        );
        if (!mounted || generation != _requestGeneration) return;
        setState(() => _messages.add(answer));
        _persistHistory();
        _maybeAutoSpeak(answer);
      }
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      _failedQuestion = question;
      setState(() => _messages.add(_errorMessage(error, wasRemote: wasRemote)));
      _persistHistory();
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() {
          _sending = false;
          _streaming = false;
          _streamText = '';
        });
        _scrollToBottom();
      }
    }
  }

  /// 在线流式回答：把逐块文本接进 `_streamText`，流结束后落定成一条消息。
  ///
  /// 用 `listen` 而不是 `await for`：要把订阅句柄存下来，用户点「取消」/「清空对话」
  /// 或离开页面时**立刻取消订阅**，底层连接才会真的断掉。`await for` 只能在下一个
  /// chunk 到达时才发现该退出了，请求卡住时等于没取消。
  ///
  /// 中途报错时保留已经收到的正文，并明确标为未完成；还没收到正文的错误
  /// 交给 `_send` 的 catch。取消、清空和离开页面仍丢弃迟到的结果。
  Future<void> _streamAnswer(
    String question,
    AssistantContext latestContext,
    List<ChatMessage> history, {
    required int generation,
  }) async {
    final result = _service.streamAsk(
      question: question,
      context: latestContext,
      history: history,
    );
    setState(() {
      _streaming = true;
      _streamText = '';
    });
    final buffer = StringBuffer();
    // 手动 complete：订阅被取消时 onDone/onError 都不会再触发，等待方要能自己醒过来。
    final finished = Completer<void>();
    late final StreamSubscription<String> subscription;
    subscription = result.stream.listen(
      (chunk) {
        buffer.write(chunk);
        if (!mounted || generation != _requestGeneration) return;
        setState(() => _streamText = buffer.toString());
        _jumpToBottom();
      },
      onError: (Object error) {
        if (!finished.isCompleted) finished.completeError(error);
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
    _abortStream = () async {
      await subscription.cancel();
      if (!finished.isCompleted) finished.complete();
    };
    Object? interruption;
    try {
      await finished.future;
    } catch (error) {
      interruption = error;
    } finally {
      _abortStream = null;
    }
    // 取消/清空/离开后迟到的流：丢弃，不再落定成回答。
    if (!mounted || generation != _requestGeneration) return;
    final raw = buffer.toString().trim();
    if (raw.isEmpty) {
      if (interruption != null) throw interruption;
      throw const AssistantException('模型服务没有返回文字。');
    }
    final incomplete = interruption != null || !result.completion.isComplete;
    final incompleteReason = interruption == null
        ? result.completion.incompleteReason
        : '${interruption is AssistantException ? interruption.message : '模型连接中断，请重试。'}'
              ' 已保留收到的内容，回答未完成。';
    final message = _service.finalizeRemote(
      raw,
      latestContext,
      extra: result.referenceNumbers,
      // 服务端没发结束标记：回答照给，末尾补一句「可能不完整」。
      incomplete: incomplete,
      incompleteReason: incompleteReason,
    );
    // 明确的中断或输出截断给重试入口；只缺结束哨兵的旧服务仍保留原有行为。
    if (interruption != null || result.completion.incompleteReason != null) {
      _failedQuestion = question;
    }
    setState(() {
      _messages.add(message);
      _streaming = false;
      _streamText = '';
    });
    _persistHistory();
    _maybeAutoSpeak(message);
  }

  /// 失败气泡：来源按提问那一刻的上游标，文案固定、不回显任何上游内容。
  ///
  /// 标 `isError`：这不是模型说的话，多轮上下文不该把它回灌给模型。
  ChatMessage _errorMessage(Object error, {required bool wasRemote}) =>
      ChatMessage(
        role: ChatRole.assistant,
        text: error is AssistantException
            ? error.message
            : '暂时无法读取记录或获取回答，请稍后重试。',
        createdAt: DateTime.now(),
        source: wasRemote ? ChatSource.online : ChatSource.local,
        isError: true,
      );

  /// 切换上游。回本地是一步；切在线时如果已经配置过 API 也是一步。
  Future<void> _changeMode(bool remote) async {
    if (_sending || remote == _service.isRemote) return;
    if (!remote) {
      setState(() {
        _service = AssistantService();
        _onlineProfileId = null;
      });
      _appendNotice('已切回本地摘要，不联网。');
      return;
    }
    // 已经配置过就直接用选中的那条，不再弹窗——用户要的是「点一下就切」。
    final profile = await selectedProfile(_store);
    if (!mounted) return;
    if (profile == null) {
      await _openConsole();
      return;
    }
    AssistantService service;
    try {
      service = AssistantService(provider: profile.toProvider(), isRemote: true);
    } catch (_) {
      // 地址不完整、Key 被清掉：去控制台让用户补全，而不是在这里报错。
      await _openConsole();
      return;
    }
    setState(() {
      _service = service;
      _onlineProfileId = profile.id;
    });
    _appendNotice(_onlineNotice);
  }

  /// 切到在线的分隔提示。多轮开关开启时，文案要如实说明会把本轮问答带出去。
  String get _onlineNotice => _sendHistory
      ? '已启用在线助手。每次提问发送本次问题、当前统计摘要和本轮更早的问答；'
            '原始记录与设备标识不上传。'
      : '已启用在线助手。每次提问只发送本次问题和当前统计摘要；历史对话不上传。';

  Future<void> _openConsole() async {
    if (_sending) return;
    final service = await showDialog<AssistantService>(
      context: context,
      builder: (_) => AssistantApiConsole(store: _store),
    );
    if (!mounted) return;
    if (service != null) {
      // 用户点了「使用」：控制台已把这条档案设为选中并返回对应服务。
      // 记下档案 id，下次删除/编辑后据此判断要不要切回本地或重建服务。
      final profile = await selectedProfile(_store);
      if (!mounted) return;
      setState(() {
        _service = service;
        _onlineProfileId = profile?.id;
      });
      _appendNotice(_onlineNotice);
      return;
    }
    // 用户只是关闭，或在里面删除/编辑了配置：按落盘结果对齐正在使用的服务。
    await _reconcileAfterConsole();
  }

  /// 控制台关闭后，把正在使用的在线服务与落盘结果对齐。
  ///
  /// 用户在控制台里删除/编辑配置时，页面拿不到「动了哪条」的信号，只能靠
  /// 记住的档案 id 去核对：id 对应的档案没了 → 立即切回本地，不再用旧 Key；
  /// 档案还在但内容变了 → 用新内容重建服务。
  Future<void> _reconcileAfterConsole() async {
    if (!_service.isRemote) return;
    final state = await _store.load();
    if (!mounted) return;
    final profile = state.profileById(_onlineProfileId);
    if (profile == null) {
      setState(() {
        _service = AssistantService();
        _onlineProfileId = null;
      });
      _appendNotice('已删除当前使用的模型配置，已切回本地，不再调用该服务。');
      return;
    }
    AssistantService service;
    try {
      service = AssistantService(provider: profile.toProvider(), isRemote: true);
    } catch (_) {
      setState(() {
        _service = AssistantService();
        _onlineProfileId = null;
      });
      _appendNotice('当前模型配置不完整，已切回本地。');
      return;
    }
    setState(() => _service = service);
  }

  /// 切换上游时插入一条分隔提示，**不再清空对话**。
  ///
  /// 清空看起来只是「干净」，实际是把用户的东西删了：刚在本地问到的答案、
  /// 在线追问的上下文，切一下模式就全没了。历史里每条回答都带来源标，
  /// 本地答和在线答混着看也不会认错，所以没有清空的必要。
  void _appendNotice(String notice) {
    setState(
      () => _messages.add(
        ChatMessage(
          role: ChatRole.system,
          text: notice,
          createdAt: DateTime.now(),
        ),
      ),
    );
    _persistHistory();
    _scrollToBottom();
  }

  /// 取消进行中的提问：丢弃这次结果，并**真的中断**底层请求。
  ///
  /// 两件事缺一不可：加代次让迟到的回答/错误作废；取消订阅让请求停下来，
  /// 否则模型还在生成、token 还在烧，用户却以为已经取消了。
  void _cancelPending() {
    if (!_sending) return;
    _requestGeneration++;
    unawaited(_abortStream?.call() ?? Future<void>.value());
    setState(() {
      _sending = false;
      _streaming = false;
      _streamText = '';
    });
    _appendNotice('已取消本次问答。');
  }

  /// 清空本机聊天记录。
  ///
  /// 聊天已经落盘，就必须给删除入口：内容里有记录摘要和在线回答，
  /// 用户要能一键抹掉，而不是只能去系统设置里清应用数据。
  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空对话？'),
        content: const Text('会删除本机保存的聊天记录。用药记录本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 让进行中的回答失效：迟到的回答/错误不该落进清空后的对话。「停止等待」和
    // 「清掉旧问题的重试入口、朗读」也在这里一起做。
    _requestGeneration++;
    _failedQuestion = null;
    // 光作废结果不够：要取消订阅，请求才真的停下。
    await _abortStream?.call();
    await _stopSpeaking();
    await _chatStore.clear();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _streaming = false;
      _streamText = '';
      _messages
        ..clear()
        ..add(_welcomeMessage());
    });
    _persistHistory();
  }

  List<PopupMenuEntry<String>> _menuItems() => [
    const PopupMenuItem(value: 'clear', child: Text('清空对话')),
    CheckedPopupMenuItem(
      value: 'history',
      checked: _sendHistory,
      child: const Text('带上本轮对话'),
    ),
    const PopupMenuItem(value: 'speech', child: Text('朗读设置')),
    CheckedPopupMenuItem(
      value: 'largeText',
      checked: _largeText,
      child: const Text('大字模式'),
    ),
  ];

  Widget _buildOverflowMenu() => PopupMenuButton<String>(
    tooltip: '更多',
    onSelected: _onMenuSelected,
    itemBuilder: (_) => _menuItems(),
  );

  Future<void> _onMenuSelected(String value) async {
    if (value == 'clear') {
      await _clearConversation();
      return;
    }
    if (value == 'history') {
      await _toggleHistory();
      return;
    }
    if (value == 'speech') {
      await _showSpeechSettings();
      return;
    }
    if (value == 'largeText') {
      _toggleLargeText();
    }
  }

  Future<void> _toggleHistory() async {
    setState(() => _sendHistory = !_sendHistory);
    _persistSettings();
  }

  Future<void> _toggleLargeText() async {
    setState(() => _largeText = !_largeText);
    _persistSettings();
  }

  /// 朗读设置：自动朗读开关 + 语速/音调滑杆。保存后立即生效并落盘。
  Future<void> _showSpeechSettings() async {
    var autoSpeak = _autoSpeak;
    var rate = _speechRate;
    var pitch = _speechPitch;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('朗读设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('回答后自动朗读'),
                subtitle: const Text('新问题会打断上一段朗读'),
                value: autoSpeak,
                onChanged: (value) =>
                    setDialogState(() => autoSpeak = value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('语速 · ${_rateLabel(rate)}'),
                subtitle: Slider(
                  value: rate,
                  min: 0,
                  max: 1,
                  divisions: 10,
                  onChanged: (value) => setDialogState(() => rate = value),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('音调 · ${_pitchLabel(pitch)}'),
                subtitle: Slider(
                  value: pitch,
                  min: 0.5,
                  max: 2,
                  divisions: 15,
                  onChanged: (value) => setDialogState(() => pitch = value),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _autoSpeak = autoSpeak;
      _speechRate = rate;
      _speechPitch = pitch;
    });
    _persistSettings();
  }

  String _rateLabel(double rate) => switch (rate) {
    <= 0.25 => '慢',
    >= 0.75 => '快',
    _ => '正常',
  };

  String _pitchLabel(double pitch) {
    if (pitch < 0.85) return '低';
    if (pitch > 1.15) return '高';
    return '正常';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 流式输出逐块刷新时用直接跳到底部，避免每个 chunk 都发起一段滚动动画叠起来。
  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = _service.isRemote ? _onlineAccent : _localAccent;
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('记录助手'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _searching = !_searching;
              _searchQuery = '';
            }),
            icon: Icon(_searching ? Icons.search_off : Icons.search),
            tooltip: '搜索对话',
          ),
          IconButton(
            onPressed: _sending ? null : _openConsole,
            icon: Icon(Icons.settings_outlined, color: accent),
            tooltip: '管理 API',
          ),
          _buildOverflowMenu(),
        ],
      ),
      // 键盘弹起时可用高度会变小。真正占高的摘要卡放进可滚动区随内容滚走，
      // 输入栏固定在底部——这样就不会再出现「输入框被挤出屏幕、看不到打的字」的
      // RenderFlex 溢出（原来摘要卡是固定项，键盘一来就把输入栏顶出屏幕）。
      body: SafeArea(
        child: Column(
          children: [
            _buildModeBar(),
            if (_searching) _buildSearchBar(),
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                children: [
                  // 搜索时收起始摘要卡，聚焦结果；搜索词为空仍显示摘要。
                  if (!_searching || _searchQuery.trim().isEmpty)
                    _buildSummaryCard(),
                  for (final message in _visibleMessages())
                    _buildMessage(message),
                  if (!_searching) ...[
                    if (_sending && !_streaming) _buildThinkingBubble(),
                    if (_streaming) _buildStreamingBubble(),
                    _buildFollowUps(),
                    _buildRetryBar(),
                  ],
                ],
              ),
            ),
            // 快捷问题留在固定区：它是「随时点一下」的入口，滚走了就不好用。
            _buildQuickQuestions(),
            _buildInputBar(),
          ],
        ),
      ),
    );

    // 大字模式：在系统字号基础上再放大一档，方便长辈阅读。
    if (!_largeText) return page;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    // clamp 返回 num，TextScaler.linear 要 double，这里显式转回 double。
    final largeScale = (systemScale * 1.25).clamp(1.0, 2.2).toDouble();
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(largeScale),
      ),
      child: page,
    );
  }

  /// 常驻的模式切换条。
  ///
  /// 之前切换藏在右上角菜单里，用户找不到、也看不出当前在用什么；现在直接显示
  /// 本地/在线两段，选中态就是当前上游。
  Widget _buildModeBar() {
    final remote = _service.isRemote;
    final accent = remote ? _onlineAccent : _localAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('本地'),
                  icon: Icon(Icons.offline_bolt_outlined, size: 16),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('在线'),
                  icon: Icon(Icons.cloud_outlined, size: 16),
                ),
              ],
              selected: {remote},
              // 选中段直接上识别色，一眼看出现在问的是谁。选中态是
              // WidgetState.selected，只能靠 resolveWith 表达（不能整段染色，
              // 否则未选中的那段也跟着变色，就看不出选的是哪个了）。
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.selected) ? accent : null,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Colors.white
                      : null,
                ),
              ),
              onSelectionChanged: _sending
                  ? null
                  : (selection) => _changeMode(selection.single),
            ),
          ),
          if (remote) ...[
            const SizedBox(height: 8),
            _buildPrivacyBanner(),
          ],
        ],
      ),
    );
  }

  /// 在线时把「按下发送会发生什么」放在输入框上方，而不是只写在设置页里。
  Widget _buildPrivacyBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _assistantBubbleColor(ChatSource.online),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.privacy_tip_outlined,
            size: 16,
            color: _sourceAccent(ChatSource.online),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sendHistory
                  ? '每次提问把「本次问题 + 上方摘要 + 本轮更早的问答」发给你的模型；'
                        '原始记录与设备标识不上传。'
                  : '每次提问只把「本次问题 + 上方摘要」发给在线模型，'
                        '不发送原始记录、设备标识或历史对话。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final data = _context;
    return Card(
      // 横向留白由外层 ListView 给，卡片自己只管上下间距。
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _buildSyncBadge(data),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // 三列都得能被压窄。Row 里没有弹性项时，每一项都按文字固有宽度占位，
                // 系统字号放大后「近 7 天疑似无效」这种长标签就会把整行顶出卡片
                // （实测 1.5 倍字号、375 宽时横向溢出 12 像素）。
                Flexible(
                  child: _summaryItem(
                    data.isDemo ? '今日 · 演示' : '今日',
                    '${data.todayCount} 次',
                  ),
                ),
                Flexible(
                  child: _summaryItem('近 7 天', '${data.last7DaysCount} 次'),
                ),
                Flexible(
                  child: _summaryItem(
                    '近 7 天疑似无效',
                    '${data.invalidEventCount} 条',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _buildDailyBars(data),
          ],
        ),
      ),
    );
  }

  /// 同步状态徽章：演示/未同步/可能不是最新/已同步，一眼看出数据新不新。
  Widget _buildSyncBadge(AssistantContext data) {
    final status = syncStatus(data, DateTime.now());
    final (icon, color) = switch (status) {
      SyncStatus.demo => (Icons.science_outlined, const Color(0xff8a6d1f)),
      SyncStatus.never => (Icons.sync_disabled, const Color(0xffc62828)),
      SyncStatus.stale => (Icons.sync_problem, const Color(0xffc62828)),
      SyncStatus.fresh => (
        Icons.check_circle_outline,
        const Color(0xff2e7d32),
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          syncStatusLabel(status),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }

  /// 把助手实际读到的逐日数据画出来，让用户看得见助手“知道什么”，
  /// 而不是只面对三个汇总数字。点某根柱子可以看当天确切次数。
  Widget _buildDailyBars(AssistantContext data) {
    final max = data.dailyCounts.fold<int>(
      1,
      (current, count) => math.max(current, count),
    );
    // 柱子上的数字会随系统字号放大，柱区高度也跟着放大，否则大字体会把它撑爆
    // （同一类溢出：固定高度装不下会被 textScaler 放大的文字）。
    final scale = MediaQuery.textScalerOf(context).scale(1);
    const barAreaHeight = 52.0;
    const maxBarHeight = 28.0;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '近 7 天逐日使用动作（左最早，右今天）',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: barAreaHeight * scale,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var index = 0; index < data.dailyCounts.length; index++)
                Expanded(
                  child: Semantics(
                    label:
                        '第 ${index + 1} 天，${data.dailyCounts[index]} 次使用动作',
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showDayCount(
                        index,
                        data.dailyCounts[index],
                        isToday: index == data.dailyCounts.length - 1,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '${data.dailyCounts[index]}',
                            style: const TextStyle(fontSize: 10),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 14,
                            height: math.max(
                              3,
                              data.dailyCounts[index] / max * maxBarHeight * scale,
                            ),
                            decoration: BoxDecoration(
                              color: _barColor(
                                index,
                                data.dailyCounts[index],
                                data.dailyCounts.length,
                                scheme,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '共 ${data.totalCount} 条本地记录'
          '${data.lastSyncAt == null ? '' : ' · 最后同步 ${data.lastSyncAt!.toLocal()}'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 柱子的颜色：今天实心强调，其余淡色，空档日用更浅的占位色。
  Color _barColor(int index, int count, int length, ColorScheme scheme) {
    if (index == length - 1) return scheme.primary;
    if (count == 0) return scheme.outlineVariant;
    // 用 withValues 而不是 withOpacity：后者已废弃（有精度损失），
    // 而本仓库把 analyze 的 info 也当致命错误，留着会让整个 job 挂掉。
    return scheme.primary.withValues(alpha: 0.5);
  }

  void _showDayCount(int index, int count, {required bool isToday}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${isToday ? '今天' : '第 ${index + 1} 天'} · $count 次使用动作'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Widget _summaryItem(String title, String value) {
    return Column(
      children: [
        // 被压窄后标题会折行，居中才不像排版事故。
        Text(
          title,
          style: Theme.of(context).textTheme.labelMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 助手气泡的底色。
  ///
  /// 只有一套浅色主题（外观切换已移除），所以每个来源只写一种颜色，
  /// 不再按 `Brightness` 分深浅两套。
  Color _assistantBubbleColor(ChatSource? source) {
    return switch (source) {
      ChatSource.knowledge => const Color(0xfffdf3dc),
      ChatSource.online => const Color(0xffe6eafb),
      _ => const Color(0xffe0efed),
    };
  }

  /// 来源小标的颜色。同样只有一套（浅色）配色。
  Color _sourceAccent(ChatSource source) {
    return switch (source) {
      ChatSource.knowledge => const Color(0xff8a6d1f),
      ChatSource.online => _onlineAccent,
      ChatSource.local => _localAccent,
    };
  }

  /// 来源小标的图标与文字。
  ///
  /// 措辞用「本地回答 / 在线回答 / AI 知识」，与分段控件的「本地 / 在线」不同字，
  /// 这样界面上的两处标签不会互相混淆（测试里也靠这一点区分）。
  ({String label, IconData icon}) _sourceBadge(ChatSource source) =>
      switch (source) {
        ChatSource.local => (
          label: '本地回答',
          icon: Icons.offline_bolt_outlined,
        ),
        ChatSource.online => (label: '在线回答', icon: Icons.cloud_outlined),
        ChatSource.knowledge => (
          label: 'AI 知识',
          icon: Icons.lightbulb_outline,
        ),
      };

  Widget _buildMessage(ChatMessage message) {
    if (message.isNotice) return _buildNotice(message);
    final colorScheme = Theme.of(context).colorScheme;
    final source = message.source;
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        // 读屏时需要听出这是谁说的话，否则提问和回答会混在一起。
        label: '${message.isUser ? '我的提问' : '助手回答'}：${message.text}',
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 330),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: message.isUser
                ? colorScheme.primaryContainer
                : _assistantBubbleColor(source),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 用户提问不带来源标：问句本身没有来源差异。
              if (!message.isUser && source != null) ...[
                _buildSourceBadge(source),
                const SizedBox(height: 4),
              ],
              // 助手回答带强调：声明浅色、个人数据蓝色、问题红色、正文黑色。
              if (message.isUser) Text(message.text) else _buildAnswerText(message),
              // 助手回答可以朗读，也能给赞/踩反馈。
              if (!message.isUser) ...[
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSpeakButton(message),
                      _buildFeedback(message),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceBadge(ChatSource source) {
    final badge = _sourceBadge(source);
    final accent = _sourceAccent(source);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(badge.icon, size: 12, color: accent),
        const SizedBox(width: 4),
        Text(
          badge.label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: accent,
          ),
        ),
      ],
    );
  }

  /// 「朗读 / 停止」按钮：只在助手气泡里出现，用户自己的提问不提供朗读。
  ///
  /// 正在读这一条时按钮变成「停止」，再点一次就停——朗读因此有了开关，
  /// 而不是点下去只能等它读完。
  Widget _buildSpeakButton(ChatMessage message) {
    final speaking = identical(_speakingMessage, message);
    return TextButton.icon(
      onPressed: () => _speak(message),
      icon: Icon(
        speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
        size: 16,
      ),
      label: Text(speaking ? '停止' : '朗读'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// 「有帮助 / 没帮助」反馈：只在助手气泡里，用户提问不提供。反馈只落在本地界面，
  /// 不回传模型、也不落盘。
  Widget _buildFeedback(ChatMessage message) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () => _rate(message, ChatFeedback.up),
          icon: Icon(
            message.feedback == ChatFeedback.up
                ? Icons.thumb_up
                : Icons.thumb_up_outlined,
            size: 16,
          ),
          visualDensity: VisualDensity.compact,
          tooltip: '有帮助',
        ),
        IconButton(
          onPressed: () => _rate(message, ChatFeedback.down),
          icon: Icon(
            message.feedback == ChatFeedback.down
                ? Icons.thumb_down
                : Icons.thumb_down_outlined,
            size: 16,
          ),
          visualDensity: VisualDensity.compact,
          tooltip: '没帮助',
        ),
      ],
    );
  }

  /// 给一条助手回答记反馈。赞只做标记；「踩」在线/知识回答时，不回传反馈，
  /// 只用本地规则把同一问题重新解释一遍作对比。
  Future<void> _rate(ChatMessage message, ChatFeedback feedback) async {
    final index = _messages.indexOf(message);
    if (index < 0) return;
    final toggled = message.feedback == feedback ? ChatFeedback.none : feedback;
    setState(() {
      _messages[index] = message.copyWith(feedback: toggled);
      // 正在读这一条时把朗读目标一起换成副本，否则「停止」与高亮会跟着丢。
      if (identical(_speakingMessage, message)) {
        _speakingMessage = _messages[index];
      }
    });
    if (feedback == ChatFeedback.down &&
        toggled == ChatFeedback.down &&
        message.source != ChatSource.local) {
      // 传下标而不是 message：上一步已经用 copyWith 把列表里那个对象换掉了，
      // 再拿 message 去 indexOf 会得到 -1（这里踩过，表现为「踩了没反应」）。
      final question = _questionBefore(index);
      if (question == null) return;
      _appendNotice('已记录这条回答没帮助（不会发送给模型）。下面用本地规则重新解释：');
      final local = await AssistantService().ask(
        question: question,
        context: _context,
      );
      if (!mounted) return;
      setState(() => _messages.add(local));
      _persistHistory();
      _scrollToBottom();
    }
  }

  /// 这条回答对应的那个提问（往前找最近的用户消息）。
  ///
  /// 收的是**下标**而不是消息对象：调用方常常刚用 `copyWith` 替换过列表里的对象，
  /// 那时原对象已经不在 `_messages` 里，`indexOf` 会返回 -1。
  String? _questionBefore(int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _messages[i].text;
    }
    return null;
  }

  /// 回答正文：把声明/个人数据/问题/正文拆成不同样式（见 answer_styling.dart）。
  ///
  /// 正在朗读这条回答时，**还没读到的部分显示成灰色**，用户能看出读到哪里了。
  Widget _buildAnswerText(ChatMessage message) {
    // 通用知识回答里的数字是科普（如「全球约 3 亿人」），不是用户记录，不标蓝。
    final dataNumbers = message.source == ChatSource.knowledge
        ? const <int>{}
        : personalDataNumbers(_context);
    final spans = styleAnswer(message.text, dataNumbers: dataNumbers);
    // 只有真在朗读、而且**引擎真的回报过进度**时才染色：不回报进度的引擎
    // （例如 Android 26 以下的设备）保持原样，否则整段会一直是灰的，
    // 那比不高亮更糟。
    final speaking = identical(_speakingMessage, message);
    final readChars = speaking && _spokenChars > 0 ? _spokenChars : null;
    return Text.rich(TextSpan(children: _answerChildren(spans, readChars)));
  }

  /// 把带样式的片段按「已读 / 未读」切开：已读保持原样式，未读换成灰色。
  ///
  /// [readChars] 为空表示「不做进度染色」——没在朗读，或者引擎还没回报进度。
  /// 未读部分仍然带着该段的字重与斜体，只是颜色变灰，所以「这段是数字还是
  /// 提醒」不会因为还没读到而看不出来。
  List<InlineSpan> _answerChildren(List<AnswerSpan> spans, int? readChars) {
    final children = <InlineSpan>[];
    var offset = 0;
    for (final span in spans) {
      final start = offset;
      final end = offset + span.text.length;
      offset = end;
      if (readChars == null || readChars >= end) {
        children.add(TextSpan(text: span.text, style: _spanStyle(span.kind)));
      } else if (readChars <= start) {
        children.add(TextSpan(text: span.text, style: _unreadStyle(span.kind)));
      } else {
        // 进度落在这一段中间：前一半已读、后一半未读。
        final cut = readChars - start;
        children.add(
          TextSpan(
            text: span.text.substring(0, cut),
            style: _spanStyle(span.kind),
          ),
        );
        children.add(
          TextSpan(text: span.text.substring(cut), style: _unreadStyle(span.kind)),
        );
      }
    }
    return children;
  }

  /// 未读部分的样式：只把颜色换成灰色，字重与斜体保留。
  TextStyle _unreadStyle(AnswerSpanKind kind) =>
      _spanStyle(kind).copyWith(color: const Color(0xff9ca3af));

  /// 每种强调的样式。单套浅色主题下的固定值，不随模式切换。
  TextStyle _spanStyle(AnswerSpanKind kind) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return switch (kind) {
      AnswerSpanKind.notice => (base ?? const TextStyle()).copyWith(
        color: const Color(0xff6b7280),
        fontStyle: FontStyle.italic,
      ),
      AnswerSpanKind.data => (base ?? const TextStyle()).copyWith(
        color: const Color(0xff1565c0),
        fontWeight: FontWeight.w600,
      ),
      AnswerSpanKind.alert => (base ?? const TextStyle()).copyWith(
        color: const Color(0xffc62828),
        fontWeight: FontWeight.w600,
      ),
      AnswerSpanKind.plain => base ?? const TextStyle(),
    };
  }

  /// 切换上游的分隔提示：居中的淡色小字，不是气泡——它不是谁说的话。
  Widget _buildNotice(ChatMessage message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          message.text,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );

  /// 在线助手最长可能等 55 秒；只靠发送按钮上的小转圈，对话区看起来像卡死了。
  /// 所以给一个「取消」，用户可以不必干等。
  Widget _buildThinkingBubble() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(_service.isRemote ? '正在询问在线助手…' : '正在读取本地统计…'),
            ],
          ),
          TextButton(
            onPressed: _cancelPending,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );

  /// 流式回答的实时气泡：在线色，逐字滚动，底部一行小字表明还在输出。
  Widget _buildStreamingBubble() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 330),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _assistantBubbleColor(ChatSource.online),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_streamText.isEmpty ? '…' : _streamText),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text(
                '正在输出',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          TextButton(
            onPressed: _cancelPending,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('停止'),
          ),
        ],
      ),
    ),
  );

  /// 搜索条：搜索对话正文（含用户提问与助手回答），不联服务器。
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索对话',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          IconButton(
            onPressed: () => setState(() {
              _searching = false;
              _searchQuery = '';
            }),
            icon: const Icon(Icons.close),
            tooltip: '关闭搜索',
          ),
        ],
      ),
    );
  }

  /// 当前要展示的消息：搜索时只留正文命中查询词的。
  List<ChatMessage> _visibleMessages() {
    final query = _searchQuery.trim().toLowerCase();
    if (!_searching || query.isEmpty) return _messages;
    return [
      for (final message in _messages)
        if (message.text.toLowerCase().contains(query)) message,
    ];
  }

  /// 追问建议：基于最近一次提问给 2–3 个「接着问」。没有提问时不显示。
  Widget _buildFollowUps() {
    final lastQuestion = _lastUserQuestion();
    if (lastQuestion == null || _sending) return const SizedBox.shrink();
    final suggestions = followUpsFor(lastQuestion);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('接着问', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final suggestion in suggestions)
                InputChip(
                  label: Text(suggestion),
                  onPressed: _sending ? null : () => _send(suggestion),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String? _lastUserQuestion() {
    for (final message in _messages.reversed) {
      if (message.isUser) return message.text;
    }
    return null;
  }

  /// 回答失败后的「重试」入口：重新发送同一条问题。
  Widget _buildRetryBar() {
    final question = _failedQuestion;
    if (question == null || _sending) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          avatar: const Icon(Icons.refresh, size: 16),
          label: const Text('上次回答失败，点这里重试'),
          onPressed: () => _send(question),
        ),
      ),
    );
  }

  /// 快捷问题。每个都能在本地模式下拿到确定答案，不靠在线模型。
  static const _quickQuestions = [
    '今天用了几次？',
    '最近有异常吗？',
    '查看最近一周',
    '有什么建议？',
    '数据是最新的吗？',
    '设备时间对吗？',
    '一共有多少条记录？',
    '空白那几天怎么看？',
    '能问什么？',
  ];

  Widget _buildQuickQuestions() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    // 不给固定高度：系统字号放大时，固定高度会把 chip 里的文字挤爆。
    child: Row(
      children: [for (final question in _quickQuestions) _quickQuestion(question)],
    ),
  );

  Widget _quickQuestion(String question) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ActionChip(
        label: Text(question),
        onPressed: _sending ? null : () => _send(question),
      ),
    );
  }

  Widget _buildInputBar() {
    final remote = _service.isRemote;
    final accent = remote ? _onlineAccent : _localAccent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              maxLength: 1000,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                // 在线模式可以问记录以外的问题，提示语跟着说清楚；本地模式答不了，
                // 就不要许这个愿。
                hintText: remote ? '问记录，也可以问健康常识' : '输入关于记录的问题',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            style: IconButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
            ),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }
}
