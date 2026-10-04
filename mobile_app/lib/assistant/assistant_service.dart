import 'answer_verification.dart';
import 'assistant_knowledge.dart';
import 'assistant_provider.dart';
import 'history_relevance.dart';
import 'models/assistant_context.dart';
import 'models/chat_message.dart';
import 'providers/mock_assistant_provider.dart';

class AssistantService {
  AssistantService({
    AssistantProvider? provider,
    this.isRemote = false,
    DateTime? now,
  }) : _provider = provider ?? MockAssistantProvider(),
       // 命名参数不能叫 `_now`，只能用公开名 `now` 显式赋值；同 ble_service.dart。
       _now = now; // ignore: prefer_initializing_formals

  final AssistantProvider _provider;
  final bool isRemote;

  /// 注入固定时间便于测试；本地规则自己会读当前时间，这里只有回验需要它。
  final DateTime? _now;

  /// 当前在线 provider 是否支持增量流式输出。
  bool get supportsStreaming => _provider is StreamingAssistantProvider;

  Future<ChatMessage> ask({
    required String question,
    required AssistantContext context,
  }) async {
    // 只有在线模式检索设备知识库：本地规则不联网、也不看这份语料。
    final chunks = isRemote
        ? retrieveKnowledge(question)
        : const <KnowledgeChunk>[];
    final references = [for (final chunk in chunks) chunk.toReference()];
    final referenceNumbers = _referenceNumbers(chunks);

    final answer = await _provider.reply(
      question: question,
      context: context,
      references: references,
    );
    if (!isRemote) {
      // 本地回答就是由同一份摘要算出来的，不存在编造，也没有来源标记可拆。
      return ChatMessage(
        role: ChatRole.assistant,
        text: answer,
        createdAt: DateTime.now(),
        source: ChatSource.local,
      );
    }
    return finalizeRemote(answer, context, extra: referenceNumbers);
  }

  /// 在线流式回答：先算好检索结果，再返回 raw 文本流。
  ///
  /// 页面把流逐块接进气泡；流结束后调用 [finalizeRemote] 把整段回答落定
  /// （拆来源标记、补「不是设备记录」、做数字回验）。调用前需确认
  /// [supportsStreaming] 为 true。
  ({
    List<String> references,
    Set<int> referenceNumbers,
    Stream<String> stream,
    StreamCompletion completion,
  })
  streamAsk({
    required String question,
    required AssistantContext context,
    List<ChatMessage> history = const [],
  }) {
    final chunks = retrieveKnowledge(question);
    final references = [for (final chunk in chunks) chunk.toReference()];
    final referenceNumbers = _referenceNumbers(chunks);
    final provider = _provider as StreamingAssistantProvider;
    // 由 provider 填写：没收到结束哨兵时置为「未确认收完」，页面据此在回答末尾补提醒。
    final completion = StreamCompletion();
    return (
      references: references,
      referenceNumbers: referenceNumbers,
      completion: completion,
      stream: provider.replyStream(
        question: question,
        context: context,
        references: references,
        history: _toTurns(history, question: question),
        completion: completion,
      ),
    );
  }

  /// 把页面给的历史整理成只含 user/assistant 的干净回合，再按当前问题做相关性
  /// 裁剪（见 `history_relevance.dart`），供直连模型多轮上下文用。
  ///
  /// 来源标记在落盘前已拆掉，这里再拆一次是防老存档里还带着标记。
  /// **失败气泡要滤掉**：那是 App 写的提示、不是模型说过的话，回灌过去会让模型
  /// 把自己上一条「模型服务响应超时」当成已经答过的内容。
  List<ChatTurn> _toTurns(
    List<ChatMessage> history, {
    required String question,
  }) {
    final turns = <ChatTurn>[];
    for (final message in history) {
      if (message.isUser) {
        turns.add((role: 'user', text: message.text));
      } else if (message.role == ChatRole.assistant &&
          !message.isError &&
          !message.isIncomplete) {
        turns.add((
          role: 'assistant',
          text: parseRemoteAnswer(message.text).body,
        ));
      }
    }
    return relevantTurns(turns, question);
  }

  /// 在线回答落定：拆来源标记、补「不是设备记录」说明、做数字回验。
  ///
  /// 流式和非流式两条路径共用这一步，保证两边的回答长得一模一样。
  ///
  /// [incomplete] 为 true 时（流没收结束标记就断了）在末尾补一句提醒——回答照给，
  /// 但要让用户知道这次没确认收完。
  ChatMessage finalizeRemote(
    String raw,
    AssistantContext context, {
    Set<int> extra = const {},
    bool incomplete = false,
    String? incompleteReason,
  }) {
    final parsed = parseRemoteAnswer(raw);
    // 没确认收完就补一句提醒；回答本身照给。
    final tail = incomplete
        ? '\n\n${incompleteReason == null ? remoteIncompleteNote : '（$incompleteReason）'}'
        : '';
    if (parsed.isKnowledge) {
      // 通用知识回答不参与数字回验：里面的数字（例如「全球约 3 亿人」）本来就不
      // 来自摘要，拿摘要去比对只会把正常回答误判成编造，还得跟一句莫名其妙的提醒。
      return ChatMessage(
        role: ChatRole.assistant,
        // 声明放在最前面、浅色斜体渲染（见 answer_styling.dart），让用户先看到
        // 「这不是你的设备记录」，再读正文。
        text: '$remoteKnowledgeNote\n\n${parsed.body}$tail',
        createdAt: DateTime.now(),
        source: ChatSource.knowledge,
        isIncomplete: incomplete,
      );
    }
    return ChatMessage(
      role: ChatRole.assistant,
      // 只有用到记录的联网回答需要回验。
      text:
          verifyRemoteAnswer(parsed.body, context, now: _now, extra: extra) +
          tail,
      createdAt: DateTime.now(),
      source: ChatSource.online,
      isIncomplete: incomplete,
    );
  }

  /// 检索到的知识里出现过的数字要放行进回验，见 answer_verification.dart。
  Set<int> _referenceNumbers(List<KnowledgeChunk> chunks) => <int>{
    for (final chunk in chunks) ...[
      ...numbersInText(chunk.title),
      ...numbersInText(chunk.body),
    ],
  };
}
