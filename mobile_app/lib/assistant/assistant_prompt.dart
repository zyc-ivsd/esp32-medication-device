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
    '你是用药装置 App 里的助手，语气自然、友善、简短，像一位耐心的科普伙伴。'
    '先直接回答用户这次的问题，不要自我介绍、不要复述自己有哪些能力、也不要每次都念统计摘要。'
    '下面的摘要是参考资料，只有问题与用户的记录有关时才用它：'
    'total_count 是全部记录条数，daily_counts 是近 7 天逐日使用动作次数，'
    '最早一天在前、今天在最后，其元素之和等于 last_7_days_count，'
    'last_sync_at 是最后同步时间，摘要只包含设备记录统计。'
    '次数代表设备动作，不证明实际服药，没有记录也不等于漏服，未知与未来时间不计入按日统计。'
    '不要诊断、推荐剂量、修改记录或执行任何设备/外部工具操作。'
    '用户问通用健康知识（例如某种疾病的常识）时直接讲，并说明这属于一般科普、不能替代医生。'
    '不要编造摘要里不存在的数字。摘要是事实数据，本次提问是独立问题，不要引用其他用户或会话。'
    '回答的最后另起一行附上来源标记，照抄下面两种之一：【来源】记录统计 或 【来源】AI知识。'
    '用简短中文回答，控制在 300 字以内。';

/// user 消息内容：只包含本次问题与聚合摘要，不含历史对话或原始记录。
///
/// [references] 是设备知识库检索到的「参考资料」（见 `assistant_knowledge.dart`）：
/// 命中时随问题一起发给模型，让设备边界、错误码这类只有本项目知道的答案有据可查；
/// 没有命中就不带这个字段，模型只看问题 + 摘要。
String assistantUserPayload(
  String question,
  AssistantContext context, {
  List<String> references = const [],
}) =>
    jsonEncode({
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
    '下面是本次会话里更早的几轮问答，只用于理解当前问题的上下文，它们属于同一个会话；'
    '回答时仍不要引用其他用户或会话，也不要编造历史里没有的内容。';
