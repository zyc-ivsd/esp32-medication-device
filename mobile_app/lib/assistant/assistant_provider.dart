import 'models/assistant_context.dart';

/// AI 服务的统一接口。
///
/// 第一阶段使用 MockAssistantProvider；后续可以增加 HTTP/WebSocket
/// Provider，而不需要修改页面和同步逻辑。
abstract class AssistantProvider {
  Future<String> reply({
    required String question,
    required AssistantContext context,
  });
}
