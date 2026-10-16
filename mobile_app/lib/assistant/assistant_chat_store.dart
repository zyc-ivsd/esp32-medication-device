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

/// Stores chat history locally. Storage failures do not interrupt the session.
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
