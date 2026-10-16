import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'assistant_chat_store.dart';
import 'assistant_service.dart';
import 'assistant_settings.dart';
import 'assistant_exception.dart';
import 'assistant_tts.dart';
import 'answer_styling.dart';
import 'follow_up_suggestions.dart';
import 'sync_status.dart';
import 'models/assistant_context.dart';
import 'models/chat_message.dart';

const _localAccent = Color(0xff75518c);
const _archivedAnswerAccent = Color(0xff9b5832);

class AssistantPage extends StatefulWidget {
  const AssistantPage({
    super.key,
    this.service,
    this.assistantContext = const AssistantContext(),
    this.contextLoader,
    this.chatStore,
    this.speaker,
    this.settingsStore,
  });

  final AssistantService? service;
  final AssistantContext assistantContext;
  final Future<AssistantContext> Function()? contextLoader;
  final AssistantChatStore? chatStore;
  final AssistantSpeaker? speaker;
  final AssistantSettingsStore? settingsStore;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  late AssistantService _service;
  late final AssistantChatStore _chatStore;
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  late final List<ChatMessage> _messages;
  bool _sending = false;
  late AssistantContext _context;
  AssistantSpeaker? _speaker;
  bool _ownsSpeaker = false;

  late final AssistantSettingsStore _settingsStore;
  bool _autoSpeak = false;
  double _speechRate = 0.5;
  double _speechPitch = 1.0;
  bool _searching = false;
  String _searchQuery = '';
  bool _largeText = false;
  String? _failedQuestion;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AssistantService();
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
    if (_ownsSpeaker) unawaited(_speaker?.dispose());
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

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

  ChatMessage? _speakingMessage;
  int _spokenChars = 0;
  int _speechGeneration = 0;
  Future<void> _speak(ChatMessage message) async {
    if (identical(_speakingMessage, message)) {
      await _stopSpeaking();
      return;
    }
    final generation = ++_speechGeneration;
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
          if (!mounted || generation != _speechGeneration) return;
          if (endOffset == _spokenChars) return;
          setState(() => _spokenChars = endOffset);
        },
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Read aloud is unavailable on this device.'),
          ),
        );
      }
    } finally {
      if (mounted && generation == _speechGeneration) {
        setState(() {
          _speakingMessage = null;
          _spokenChars = 0;
        });
      }
    }
  }

  AssistantSpeaker? get _existingSpeaker => widget.speaker ?? _speaker;
  Future<void> _stopSpeakerOnly() async {
    final speaker = _existingSpeaker;
    if (speaker == null) return;
    try {
      await speaker.stop();
    } catch (_) {}
  }

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

  void _maybeAutoSpeak(ChatMessage message) {
    if (!_autoSpeak || message.isIncomplete || message.isError) return;
    unawaited(_speak(message));
  }

  ChatMessage _welcomeMessage() => ChatMessage(
    role: ChatRole.assistant,
    text:
        'Hello! I can help you understand your saved medication records. '
        'This assistant uses offline rules. '
        'A logged use does not verify ingestion.',
    createdAt: DateTime.now(),
  );
  Future<void> _loadHistory() async {
    final history = await _chatStore.load();
    if (!mounted || history.isEmpty) return;
    if (_messages.length > 1) return;
    setState(
      () => _messages
        ..clear()
        ..addAll(history),
    );
    _scrollToBottom();
  }

  Future<void> _loadSettings() async {
    final settings = await _settingsStore.load();
    if (!mounted) return;
    setState(() {
      _autoSpeak = settings.autoSpeak;
      _speechRate = settings.speechRate;
      _speechPitch = settings.speechPitch;
      _largeText = settings.largeText;
    });
  }

  void _persistHistory() => unawaited(_chatStore.save(List.of(_messages)));
  void _persistSettings() => unawaited(
    _settingsStore.save(
      AssistantSettings(
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
    await _stopSpeaking();

    _inputController.clear();
    _failedQuestion = null;
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
    });
    _persistHistory();
    _scrollToBottom();

    try {
      final latestContext =
          await widget.contextLoader?.call() ?? widget.assistantContext;
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _context = latestContext);

      final answer = await _service.ask(
        question: question,
        context: latestContext,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _messages.add(answer));
      _persistHistory();
      _maybeAutoSpeak(answer);
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      _failedQuestion = question;
      setState(() => _messages.add(_errorMessage(error)));
      _persistHistory();
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() {
          _sending = false;
        });
        _scrollToBottom();
      }
    }
  }

  ChatMessage _errorMessage(Object error) => ChatMessage(
    role: ChatRole.assistant,
    text: error is AssistantException
        ? error.message
        : 'Records or the answer could not be loaded. Please try again.',
    createdAt: DateTime.now(),
    source: ChatSource.local,
    isError: true,
  );

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

  void _cancelPending() {
    if (!_sending) return;
    _requestGeneration++;
    setState(() {
      _sending = false;
    });
    _appendNotice('Question cancelled.');
  }

  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'Saved chat messages will be deleted from this phone. Medication records are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _requestGeneration++;
    _failedQuestion = null;
    await _stopSpeaking();
    await _chatStore.clear();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _messages
        ..clear()
        ..add(_welcomeMessage());
    });
    _persistHistory();
  }

  List<PopupMenuEntry<String>> _menuItems() => [
    const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
    const PopupMenuItem(value: 'speech', child: Text('Read-aloud settings')),
    CheckedPopupMenuItem(
      value: 'largeText',
      checked: _largeText,
      child: const Text('Larger text'),
    ),
  ];

  Widget _buildOverflowMenu() => PopupMenuButton<String>(
    tooltip: 'More',
    onSelected: _onMenuSelected,
    itemBuilder: (_) => _menuItems(),
  );

  Future<void> _onMenuSelected(String value) async {
    if (value == 'clear') {
      await _clearConversation();
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

  Future<void> _toggleLargeText() async {
    setState(() => _largeText = !_largeText);
    _persistSettings();
  }

  Future<void> _showSpeechSettings() async {
    var autoSpeak = _autoSpeak;
    var rate = _speechRate;
    var pitch = _speechPitch;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Read-aloud settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Read new answers automatically'),
                subtitle: const Text(
                  'A new question stops the previous reading',
                ),
                value: autoSpeak,
                onChanged: (value) => setDialogState(() => autoSpeak = value),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Speed · ${_rateLabel(rate)}'),
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
                title: Text('Pitch · ${_pitchLabel(pitch)}'),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save'),
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
    <= 0.25 => 'Slow',
    >= 0.75 => 'Fast',
    _ => 'Normal',
  };

  String _pitchLabel(double pitch) {
    if (pitch < 0.85) return 'Low';
    if (pitch > 1.15) return 'High';
    return 'Normal';
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

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('Record assistant'),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _searching = !_searching;
              _searchQuery = '';
            }),
            icon: Icon(_searching ? Icons.search_off : Icons.search),
            tooltip: 'Search chat',
          ),
          _buildOverflowMenu(),
        ],
      ),
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
                  if (!_searching || _searchQuery.trim().isEmpty)
                    _buildSummaryCard(),
                  for (final message in _visibleMessages())
                    _buildMessage(message),
                  if (!_searching) ...[
                    if (_sending) _buildThinkingBubble(),
                    _buildFollowUps(),
                    _buildRetryBar(),
                  ],
                ],
              ),
            ),
            _buildQuickQuestions(),
            _buildInputBar(),
          ],
        ),
      ),
    );
    if (!_largeText) return page;
    final systemScale = MediaQuery.textScalerOf(context).scale(1.0);
    final largeScale = (systemScale * 1.25).clamp(1.0, 2.2).toDouble();
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(largeScale)),
      child: page,
    );
  }

  Widget _buildModeBar() => const Padding(
    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text('Offline assistant · Your records stay on this phone'),
  );

  Widget _buildSummaryCard() {
    final data = _context;
    return Card(
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
                Flexible(
                  child: _summaryItem('Today', '${data.todayCount} uses'),
                ),
                Flexible(
                  child: _summaryItem(
                    'Last 7 days',
                    '${data.last7DaysCount} uses',
                  ),
                ),
                Flexible(
                  child: _summaryItem(
                    'Invalid uses (7 days)',
                    '${data.invalidEventCount} records',
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

  Widget _buildSyncBadge(AssistantContext data) {
    final status = syncStatus(data, DateTime.now());
    final (icon, color) = switch (status) {
      SyncStatus.never => (Icons.sync_disabled, const Color(0xffc62828)),
      SyncStatus.stale => (Icons.sync_problem, const Color(0xffc62828)),
      SyncStatus.fresh => (Icons.check_circle_outline, const Color(0xff2e7d32)),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            syncStatusLabel(status),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildDailyBars(AssistantContext data) {
    final max = data.dailyCounts.fold<int>(
      1,
      (current, count) => math.max(current, count),
    );
    final scale = MediaQuery.textScalerOf(context).scale(1);
    const barAreaHeight = 52.0;
    const maxBarHeight = 28.0;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Daily uses · last 7 days (oldest to today)',
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
                    label: 'Day ${index + 1}, ${data.dailyCounts[index]} uses',
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
                              data.dailyCounts[index] /
                                  max *
                                  maxBarHeight *
                                  scale,
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
          '${data.totalCount} saved records'
          '${data.lastSyncAt == null ? '' : ' · Last sync ${data.lastSyncAt!.toLocal()}'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Color _barColor(int index, int count, int length, ColorScheme scheme) {
    if (index == length - 1) return scheme.primary;
    if (count == 0) return scheme.outlineVariant;
    return scheme.primary.withValues(alpha: 0.5);
  }

  void _showDayCount(int index, int count, {required bool isToday}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${isToday ? 'Today' : 'Day ${index + 1}'} · $count uses',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Widget _summaryItem(String title, String value) {
    return Column(
      children: [
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

  Color _assistantBubbleColor(ChatSource? source) {
    return switch (source) {
      ChatSource.knowledge => const Color(0xffffeddc),
      ChatSource.online => const Color(0xffffe1c9),
      _ => const Color(0xffe8daf3),
    };
  }

  Color _sourceAccent(ChatSource source) {
    return switch (source) {
      ChatSource.knowledge => _archivedAnswerAccent,
      ChatSource.online => _archivedAnswerAccent,
      ChatSource.local => _localAccent,
    };
  }

  ({String label, IconData icon}) _sourceBadge(ChatSource source) =>
      switch (source) {
        ChatSource.local => (
          label: 'Local answer',
          icon: Icons.offline_bolt_outlined,
        ),
        ChatSource.online => (
          label: 'Archived online answer',
          icon: Icons.cloud_outlined,
        ),
        ChatSource.knowledge => (
          label: 'Archived AI knowledge',
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
        label:
            '${message.isUser ? 'Your question' : 'Assistant answer'}: ${message.text}',
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
              if (!message.isUser && source != null) ...[
                _buildSourceBadge(source),
                const SizedBox(height: 4),
              ],
              if (message.isUser)
                Text(message.text)
              else
                _buildAnswerText(message),
              if (!message.isUser) ...[
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
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
        Flexible(
          child: Text(
            badge.label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: accent),
          ),
        ),
      ],
    );
  }

  Widget _buildSpeakButton(ChatMessage message) {
    final speaking = identical(_speakingMessage, message);
    return TextButton.icon(
      onPressed: () => _speak(message),
      icon: Icon(
        speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
        size: 16,
      ),
      label: Text(speaking ? 'Stop' : 'Read aloud'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

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
          tooltip: 'Helpful',
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
          tooltip: 'Not helpful',
        ),
      ],
    );
  }

  Future<void> _rate(ChatMessage message, ChatFeedback feedback) async {
    final index = _messages.indexOf(message);
    if (index < 0) return;
    final toggled = message.feedback == feedback ? ChatFeedback.none : feedback;
    setState(() {
      _messages[index] = message.copyWith(feedback: toggled);
      if (identical(_speakingMessage, message)) {
        _speakingMessage = _messages[index];
      }
    });
    if (feedback == ChatFeedback.down &&
        toggled == ChatFeedback.down &&
        message.source != ChatSource.local) {
      final question = _questionBefore(index);
      if (question == null) return;
      _appendNotice(
        'Feedback saved on this phone. Here is an explanation using local rules:',
      );
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

  String? _questionBefore(int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _messages[i].text;
    }
    return null;
  }

  Widget _buildAnswerText(ChatMessage message) {
    final dataNumbers = message.source == ChatSource.knowledge
        ? const <int>{}
        : personalDataNumbers(_context);
    final spans = styleAnswer(message.text, dataNumbers: dataNumbers);
    final speaking = identical(_speakingMessage, message);
    final readChars = speaking && _spokenChars > 0 ? _spokenChars : null;
    return Text.rich(TextSpan(children: _answerChildren(spans, readChars)));
  }

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
        final cut = readChars - start;
        children.add(
          TextSpan(
            text: span.text.substring(0, cut),
            style: _spanStyle(span.kind),
          ),
        );
        children.add(
          TextSpan(
            text: span.text.substring(cut),
            style: _unreadStyle(span.kind),
          ),
        );
      }
    }
    return children;
  }

  TextStyle _unreadStyle(AnswerSpanKind kind) =>
      _spanStyle(kind).copyWith(color: const Color(0xff9ca3af));
  TextStyle _spanStyle(AnswerSpanKind kind) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return switch (kind) {
      AnswerSpanKind.notice => (base ?? const TextStyle()).copyWith(
        color: const Color(0xff6b7280),
        fontStyle: FontStyle.italic,
      ),
      AnswerSpanKind.data => (base ?? const TextStyle()).copyWith(
        color: _localAccent,
        fontWeight: FontWeight.w600,
      ),
      AnswerSpanKind.alert => (base ?? const TextStyle()).copyWith(
        color: const Color(0xffc62828),
        fontWeight: FontWeight.w600,
      ),
      AnswerSpanKind.plain => base ?? const TextStyle(),
    };
  }

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
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Flexible(child: Text('Reading local statistics…')),
            ],
          ),
          TextButton(
            onPressed: _cancelPending,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search chat',
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
            tooltip: 'Close search',
          ),
        ],
      ),
    );
  }

  List<ChatMessage> _visibleMessages() {
    final query = _searchQuery.trim().toLowerCase();
    if (!_searching || query.isEmpty) return _messages;
    return [
      for (final message in _messages)
        if (message.text.toLowerCase().contains(query)) message,
    ];
  }

  Widget _buildFollowUps() {
    final lastQuestion = _lastUserQuestion();
    if (lastQuestion == null || _sending) return const SizedBox.shrink();
    final suggestions = followUpsFor(lastQuestion);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ask a follow-up',
            style: Theme.of(context).textTheme.labelSmall,
          ),
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

  Widget _buildRetryBar() {
    final question = _failedQuestion;
    if (question == null || _sending) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          avatar: const Icon(Icons.refresh, size: 16),
          label: const Text('The last request failed. Tap to try again.'),
          onPressed: () => _send(question),
        ),
      ),
    );
  }

  static const _quickQuestions = [
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

  Widget _buildQuickQuestions() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final question in _quickQuestions) _quickQuestion(question),
      ],
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
    const accent = _localAccent;
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
              decoration: const InputDecoration(
                hintText: 'Ask about your records',
                border: OutlineInputBorder(),
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
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }
}
