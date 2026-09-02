enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    required this.createdAt,
  });

  final ChatRole role;
  final String text;
  final DateTime createdAt;

  bool get isUser => role == ChatRole.user;
}
