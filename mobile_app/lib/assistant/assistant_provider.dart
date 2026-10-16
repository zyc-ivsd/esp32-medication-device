import 'models/assistant_context.dart';

/// Local response interface; injection supports deterministic tests.
abstract class AssistantProvider {
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  });
}
