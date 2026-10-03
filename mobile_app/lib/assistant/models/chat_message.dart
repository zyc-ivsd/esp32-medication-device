/// 消息的作者。
///
/// `system` 不是模型说的话，而是 App 自己的分隔提示（例如「已切回本地摘要」）。
/// 有了它，切换上游时就不必清空对话——插一条提示即可，历史仍然属于用户。
enum ChatRole { user, assistant, system }

/// 助手回答的来源。
///
/// 同屏可能出现三种来源的回答，用户必须能分清哪句是谁说的：
/// - [local]：本地规则算出来的，只基于统计摘要；
/// - [online]：在线模型，且这轮回答用到了记录/统计；
/// - [knowledge]：在线模型的通用健康知识（例如某种疾病的常识），与设备记录无关。
enum ChatSource { local, online, knowledge }

/// 用户对一条助手回答的反馈。
///
/// 只在当前会话内生效：不落盘、也不回传模型——反馈是「给本地界面的标记」，
/// 不是要发出去的内容。
enum ChatFeedback { none, up, down }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    required this.createdAt,
    this.source,
    this.feedback = ChatFeedback.none,
    this.isError = false,
  });

  final ChatRole role;
  final String text;
  final DateTime createdAt;

  /// 只有 `assistant` 角色会带上来源；用户提问与分隔提示为 null。
  final ChatSource? source;

  /// 用户对这条回答的赞/踩。会话内有效，不参与序列化。
  final ChatFeedback feedback;

  /// 这条是 App 写的失败提示，不是模型的回答（「模型服务响应超时」之类）。
  ///
  /// 界面上仍按助手气泡显示，但**不能被当成历史回灌给模型**——否则模型会看到
  /// 自己上一条失败提示，当成已经答过的内容（见 `AssistantService._toTurns`）。
  final bool isError;

  bool get isUser => role == ChatRole.user;

  /// 分隔提示，渲染成居中淡色小字而不是气泡。
  bool get isNotice => role == ChatRole.system;

  /// 只改反馈的浅拷贝，其余字段照旧。
  ChatMessage copyWith({ChatFeedback? feedback}) => ChatMessage(
    role: role,
    text: text,
    createdAt: createdAt,
    source: source,
    feedback: feedback ?? this.feedback,
    isError: isError,
  );

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'text': text,
    'created_at': createdAt.toIso8601String(),
    'source': source?.name,
    // 只在失败提示上写，正常回答不带这个字段，存档保持紧凑。
    if (isError) 'error': true,
  };

  /// 解析一条存档消息；认不出来就返回 null，由调用方跳过。
  ///
  /// 存档可能来自旧版本或被人为改坏，所以每个字段都要能容忍缺失与类型不符：
  /// 宁可少显示一条，也不能让整段历史读不出来。
  static ChatMessage? fromJson(Object? data) {
    if (data is! Map) return null;
    final role = switch (data['role']) {
      'user' => ChatRole.user,
      'assistant' => ChatRole.assistant,
      'system' => ChatRole.system,
      _ => null,
    };
    final text = data['text'];
    if (role == null || text is! String || text.isEmpty) return null;
    final createdAt = data['created_at'];
    return ChatMessage(
      role: role,
      text: text,
      // 时间戳坏掉不该让整条历史读不出来，退回当前时间。
      createdAt: createdAt is String
          ? (DateTime.tryParse(createdAt) ?? DateTime.now())
          : DateTime.now(),
      source: switch (data['source']) {
        'local' => ChatSource.local,
        'online' => ChatSource.online,
        'knowledge' => ChatSource.knowledge,
        _ => null,
      },
      // 老存档没有这个字段，认不出就是正常回答。
      isError: data['error'] == true,
    );
  }
}
