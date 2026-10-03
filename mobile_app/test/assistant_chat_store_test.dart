import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_chat_store.dart';
import 'package:medication_device_app/assistant/models/chat_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('消息能往返 JSON，角色、来源、时间都不丢', () {
    final message = ChatMessage(
      role: ChatRole.assistant,
      text: '近 7 天共 8 次。',
      createdAt: DateTime(2026, 9, 29, 10, 30),
      source: ChatSource.knowledge,
    );

    final restored = ChatMessage.fromJson(message.toJson());
    expect(restored, isNotNull);
    expect(restored!.role, ChatRole.assistant);
    expect(restored.text, message.text);
    expect(restored.source, ChatSource.knowledge);
    expect(restored.createdAt, message.createdAt);
    expect(restored.isUser, isFalse);
    expect(restored.isNotice, isFalse);
  });

  test('坏数据只丢那一条，不整段读不出来', () {
    expect(ChatMessage.fromJson(null), isNull);
    expect(ChatMessage.fromJson('不是对象'), isNull);
    expect(ChatMessage.fromJson(42), isNull);
    expect(ChatMessage.fromJson({'role': 'robot', 'text': 'x'}), isNull);
    expect(ChatMessage.fromJson({'role': 'user'}), isNull);
    expect(ChatMessage.fromJson({'role': 'user', 'text': ''}), isNull);
  });

  test('时间戳或来源认不出来时，消息本身仍然保留', () {
    final kept = ChatMessage.fromJson({
      'role': 'system',
      'text': '已切回本地摘要，不联网。',
      'created_at': '昨天',
      'source': '猜的',
    });
    expect(kept, isNotNull);
    expect(kept!.isNotice, isTrue);
    expect(kept.isUser, isFalse);
    expect(kept.source, isNull);
    expect(kept.text, '已切回本地摘要，不联网。');
  });

  test('用户提问不带来源', () {
    final restored = ChatMessage.fromJson({'role': 'user', 'text': '今天用了几次？'});
    expect(restored!.isUser, isTrue);
    expect(restored.source, isNull);
  });

  test('偏好存储不可用时静默降级，读写都不抛异常', () async {
    // 测试环境没有平台通道，getInstance 会失败——这正是不该抛异常的场景：
    // 聊天只是便利，存储坏了不该打断对话（与凭据存储的失败语义相反）。
    final store = SharedPreferencesAssistantChatStore();
    expect(await store.load(), isEmpty);
    await store.save([
      ChatMessage(
        role: ChatRole.user,
        text: '在吗',
        createdAt: DateTime(2026, 9, 29),
      ),
    ]);
    await store.clear();
  });
}
