/// A user-facing error; never display upstream payloads, URLs or credentials.
class AssistantException implements Exception {
  const AssistantException(this.message, {this.requestId});

  final String message;

  /// 网关回传的请求编号。
  ///
  /// 只有网关模式、且服务端确实返回了才有值。它的用途是让用户在不交出问题
  /// 原文或摘要的前提下，把「我看到的那条回答」和「服务端那一行」对上。
  final String? requestId;

  @override
  String toString() => message;
}
