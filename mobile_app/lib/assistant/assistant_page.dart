import 'package:flutter/material.dart';

import 'assistant_service.dart';
import 'models/assistant_context.dart';
import 'models/chat_message.dart';

class AssistantPage extends StatefulWidget {
  const AssistantPage({
    super.key,
    this.service,
    this.assistantContext = const AssistantContext(
      todayCount: 2,
      last7DaysCount: 12,
      invalidEventCount: 1,
    ),
  });

  final AssistantService? service;
  final AssistantContext assistantContext;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  late final AssistantService _service;
  late final TextEditingController _inputController;
  late final ScrollController _scrollController;
  late final List<ChatMessage> _messages;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AssistantService();
    _inputController = TextEditingController();
    _scrollController = ScrollController();
    _messages = [
      ChatMessage(
        role: ChatRole.assistant,
        text: '你好，我是用药记录助手。目前运行在 Mock 模式，可以回答记录统计问题。',
        createdAt: DateTime.now(),
      ),
    ];
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final question = (preset ?? _inputController.text).trim();
    if (question.isEmpty || _sending) return;

    _inputController.clear();
    setState(() {
      _messages.add(ChatMessage(
        role: ChatRole.user,
        text: question,
        createdAt: DateTime.now(),
      ));
      _sending = true;
    });
    _scrollToBottom();

    try {
      final answer = await _service.ask(
        question: question,
        context: widget.assistantContext,
      );
      if (!mounted) return;
      setState(() => _messages.add(answer));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          role: ChatRole.assistant,
          text: '助手暂时不可用：$error',
          createdAt: DateTime.now(),
        ));
      });
    } finally {
      if (!mounted) return;
      setState(() => _sending = false);
      _scrollToBottom();
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('用药记录助手'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Chip(
                label: const Text('Mock'),
                avatar: const Icon(Icons.science_outlined, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSummaryCard(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _buildMessage(_messages[index]),
            ),
          ),
          _buildQuickQuestions(),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final data = widget.assistantContext;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _summaryItem('今日', '${data.todayCount} 次'),
            _summaryItem('近 7 天', '${data.last7DaysCount} 次'),
            _summaryItem('疑似无效', '${data.invalidEventCount} 条'),
          ],
        ),
      ),
    );
  }

  Widget _summaryItem(String title, String value) {
    return Column(
      children: [
        Text(title, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _buildMessage(ChatMessage message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: message.isUser
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(message.text),
      ),
    );
  }

  Widget _buildQuickQuestions() {
    return SizedBox(
      height: 42,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        children: [
          _quickQuestion('今天用了几次？'),
          _quickQuestion('最近有异常吗？'),
          _quickQuestion('查看最近一周'),
        ],
      ),
    );
  }

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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '输入关于记录的问题',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
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
      ),
    );
  }
}
