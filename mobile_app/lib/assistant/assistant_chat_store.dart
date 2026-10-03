import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/chat_message.dart';

/// 聊天记录的读写接口。测试注入内存实现即可，不必碰平台通道。
abstract class AssistantChatStore {
  /// 读历史；失败时返回空列表，不抛异常。
  Future<List<ChatMessage>> load();

  /// 覆盖写入；失败时静默降级，不抛异常。
  Future<void> save(List<ChatMessage> messages);

  /// 清空本机聊天记录。
  Future<void> clear();
}

/// 用 `shared_preferences` 保存聊天记录。
///
/// **失败语义与 `SharedPreferencesAssistantCredentialsStore` 刻意不同**：
/// - 凭据（访问码 / API Key）写不进去必须报错，绝不能假装存下了——用户会以为
///   配置好了，实际下次打开就没了，甚至以为已经删掉的 Key 还在；
/// - 聊天记录只是便利：读不出来就当没有历史，写不进去也只是这次没落盘，
///   内存里的对话照常可用，不该因为存储故障打断用户。
/// 所以这里全部字段都不抛异常。谁要把凭据也改成静默降级，先回来看这段注释。
///
/// 明文存储在这里是可接受的：聊天内容与设备记录属于同一信任级（都是本机的记录
/// 摘要与解释），且**不含任何凭据**——凭据只走 `flutter_secure_storage`。
class SharedPreferencesAssistantChatStore implements AssistantChatStore {
  SharedPreferencesAssistantChatStore({this.maxMessages = 200});

  static const _key = 'assistant_chat_history';

  /// 存档上限。聊天会一直追加，不设上限的话偏好文件会无限长；
  /// 超出时丢最旧的（保留最近 [maxMessages] 条）。
  final int maxMessages;

  @override
  Future<List<ChatMessage>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      final messages = <ChatMessage>[];
      for (final entry in data) {
        final message = ChatMessage.fromJson(entry);
        if (message != null) messages.add(message);
      }
      return messages;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<ChatMessage> messages) async {
    try {
      final trimmed = messages.length > maxMessages
          ? messages.sublist(messages.length - maxMessages)
          : messages;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode([for (final message in trimmed) message.toJson()]),
      );
    } catch (_) {
      // 没落盘就算了：这次的对话还在内存里，不该为存储故障弹错误。
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // 同上。
    }
  }
}
