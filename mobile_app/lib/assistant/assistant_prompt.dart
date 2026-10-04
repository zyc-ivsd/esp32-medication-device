import 'dart:convert';

import 'models/assistant_context.dart';

/// 在线助手的 system 提示词。
///
/// 这段文本与 `server/assistant-gateway/gateway.py` 里的 `SYSTEM_PROMPT` 是同一份
/// 内容：直连模式（App → 模型）没有服务端可以承载提示词，所以必须在 App 里也有一份。
/// **改一处必须同步改另一处**，否则两种在线模式的安全约束会不一致；
/// `server/assistant-gateway/tests/test_prompt_sync.py` 会逐字比对两者。
///
/// 措辞要点（改动时别丢）：
/// - 先回答用户问的问题，摘要是参考资料而不是每轮的必答题——否则用户问什么都
///   只能听到一遍统计数字，像在跟复读机说话；
/// - 「不证明实际服药」「没有记录也不等于漏服」是必须守住的边界；
/// - 允许讲通用健康知识，但必须说明是一般科普、不能替代医生；
/// - 结尾的来源标记由 App 解析，用来区分「用了记录」还是「通用知识」
///   （见 `answer_verification.dart`），所以格式必须固定。
///
/// 注意：本文件的字符串拼接方式被 `test_prompt_sync.py` 用正则读取，正文里
/// 不能出现反斜杠转义，也不要在这段拼接中间插入带单引号的注释。
const String assistantSystemPrompt =
    'You are the assistant in the parcel medication diary app. Use friendly, clear English. '
    'Answer the current question directly, without introducing yourself or repeating a statistics summary each time. '
    'Use the record summary only when relevant to the question. '
    'total_count includes all saved records. daily_counts contains daily logged uses over the last 7 days, '
    'oldest first and today last, and its sum equals last_7_days_count. '
    'last_sync_at is the last completed device sync. The summary contains device record statistics only. '
    'Each unique valid device button timestamp logs one medication use. Counts do not verify ingestion. '
    'Missing records do not establish missed doses. Unknown and future times are excluded from daily counts. '
    'Do not diagnose, recommend doses, change records or operate devices or external tools. '
    'For general health questions, provide general educational information and explain that it cannot replace a clinician. '
    'Do not invent numbers absent from the summary, or refer to other users or sessions. '
    'End on a separate line with exactly one source marker: [Source] Records or [Source] AI knowledge. '
    'Keep answers concise but include the detail needed to answer the question.';

/// user 消息内容：只包含本次问题与聚合摘要，不含历史对话或原始记录。
///
/// [references] 是设备知识库检索到的「参考资料」（见 `assistant_knowledge.dart`）：
/// 命中时随问题一起发给模型，让设备边界、错误码这类只有本项目知道的答案有据可查；
/// 没有命中就不带这个字段，模型只看问题 + 摘要。
String assistantUserPayload(
  String question,
  AssistantContext context, {
  List<String> references = const [],
}) => jsonEncode({
  'question': question,
  'context': context.toJson(),
  if (references.isNotEmpty) 'references': references,
});

/// 多轮对话时追加在 system 提示词之后的一行。
///
/// **不并入 [assistantSystemPrompt]**：那一份要与 `gateway.py` 的 `SYSTEM_PROMPT`
/// 逐字同步，而多轮上下文只出现在直连模式，网关不支持、也不该带上历史。
/// 塞进同步的那份会破坏 `test_prompt_sync.py` 的逐字比对。这里单独放，
/// 只有用户开启「带上本轮对话」且走直连时才拼进去。
const String assistantHistoryNote =
    'Earlier turns belong to this session and provide context for the current question. '
    'Do not refer to other users or sessions or invent details absent from the conversation.';
