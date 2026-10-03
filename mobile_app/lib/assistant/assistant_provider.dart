import 'models/assistant_context.dart';

/// 一轮历史对话，供多轮上下文使用。`role` 只取 `user` / `assistant`。
///
/// 不用页面里的 `ChatMessage`：那里面还带着来源、时间戳、分隔提示这些 UI 概念，
/// provider 只需要「谁说了什么」这两个字段，传得越少越好。
typedef ChatTurn = ({String role, String text});

/// AI 服务的统一接口。
///
/// 第一阶段使用 MockAssistantProvider；后续可以增加 HTTP/WebSocket
/// Provider，而不需要修改页面和同步逻辑。
abstract class AssistantProvider {
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  });
}

/// 流式回答的收尾状态。由调用方创建、provider 填写，流结束后读 [isComplete]。
///
/// 为什么需要它：OpenAI 兼容接口正常结束会发 `data: [DONE]`，但有些服务端
/// **不发哨兵、直接关连接**，而那种情况下内容往往是完整的。所以不能因为没看到
/// 哨兵就把回答丢掉；可也无法据此确认收全了。用这个对象把「没确认收完」带回给
/// 页面，由页面在回答末尾如实提醒用户，而不是默默当成完整回答。
class StreamCompletion {
  /// 是否确认收完：收到了 `[DONE]`，或服务端不支持流式、改回整段 JSON。
  bool isComplete = true;
}

/// 支持增量流式输出的在线 provider（目前只有直连用户模型的实现）。
///
/// [reply] 仍返回整段回答；页面在「在线 + 支持流式」时改用 [replyStream]，
/// 让回答边出边显示，而不是等整段拼完才一起冒出来。网关是历史实现，
/// 不支持流式，也不支持多轮上下文，所以 [history] 只在这里出现。
///
/// 实现方要处理**订阅被取消**：页面在用户点「取消」「清空对话」或离开页面时会
/// 取消订阅，此时实现必须真的掐断底层请求（见 `DirectLlmAssistantProvider` 的
/// `onCancel`），否则请求还在跑、费用照产生。
abstract class StreamingAssistantProvider implements AssistantProvider {
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  });
}
