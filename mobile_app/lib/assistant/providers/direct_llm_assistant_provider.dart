import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../assistant_exception.dart';
import '../assistant_prompt.dart';
import '../assistant_provider.dart';
import '../models/assistant_context.dart';

/// 用**用户自己**的 API Key 直连 OpenAI 兼容接口。
///
/// 与 `GatewayAssistantProvider` 的区别：这里没有团队服务器参与，Key 由手机
/// 安全存储加载，随请求直接发给用户填写的模型服务。因此要区分两类 Key：
///
/// - **团队的/共享的 Key**：绝对不允许写进 App、APK、构建参数或仓库；
/// - **用户自己的 Key**：允许在运行时输入，由安全存储保存在手机，
///   不进日志、不上传给团队服务器。
///
/// 支持两种取回答的方式：整段（[reply]）与流式增量（[replyStream]）。
/// 页面在在线模式下优先走流式，让文字边出边显示。
///
/// 边界与风险见 `docs/assistant-model-access.md`。
class DirectLlmAssistantProvider implements StreamingAssistantProvider {
  DirectLlmAssistantProvider({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 120),
    bool allowLocalHttp = kDebugMode,
  }) : endpoint = validateBaseUrl(baseUrl, allowLocalHttp: allowLocalHttp) {
    // 在构造时报错，设置对话框才能立即提示，而不是等用户按下发送。
    if (apiKey.trim().isEmpty) {
      throw const AssistantException('Enter your model service API key first.');
    }
    if (model.trim().isEmpty) {
      throw const AssistantException(
        'Enter a model name, for example deepseek-chat.',
      );
    }
  }

  /// 已补上 `/chat/completions` 的完整地址。
  final Uri endpoint;
  final String apiKey;
  final String model;

  /// 建连、响应头和两次网络数据之间的等待上限，不限制持续输出的总时长。
  final Duration timeout;

  static const maxQuestionLength = 1000;

  /// 正文与传输包装分别限流。SSE 每个 token 都可能重复大量 JSON 字段，
  /// 不能再用 64 KB 的整包限制误伤普通长回答。
  static const maxAnswerBytes = 256 * 1024;
  static const maxResponseBytes = 2 * 1024 * 1024;
  static const maxStreamBytes = 16 * 1024 * 1024;
  static const maxSseLineBytes = 1024 * 1024;
  static const _chatPath = '/chat/completions';

  /// 只接受 HTTPS（调试版额外允许本机 HTTP），并补齐 `/chat/completions`。
  static Uri validateBaseUrl(String value, {bool allowLocalHttp = kDebugMode}) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AssistantException(
        'Enter a complete model service URL, for example https://api.deepseek.com/v1.',
      );
    }
    final localHttp =
        allowLocalHttp &&
        uri.scheme == 'http' &&
        const ['127.0.0.1', 'localhost', '10.0.2.2'].contains(uri.host);
    if (uri.scheme != 'https' && !localHttp) {
      throw const AssistantException(
        'The model service requires HTTPS. Debug builds allow HTTP only on localhost.',
      );
    }
    // 用户可能已经填了完整路径，也可能只填到 /v1，两种都接受且只补一次。
    final path = uri.path.endsWith(_chatPath)
        ? uri.path
        : uri.path.endsWith('/')
        ? '${uri.path}chat/completions'
        : '${uri.path}$_chatPath';
    return uri.replace(path: path);
  }

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || trimmed.length > maxQuestionLength) {
      throw const AssistantException('Enter a question of 1–1000 characters.');
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _request(client, trimmed, context, references);
    } on AssistantException {
      rethrow;
    } on TimeoutException {
      throw const AssistantException(
        'The model service timed out. Try again or switch to Local.',
      );
    } on SocketException {
      throw const AssistantException(
        'Cannot connect to the model service. Check the URL and network.',
      );
    } on HandshakeException {
      throw const AssistantException(
        'The service certificate could not be verified. Check the URL.',
      );
    } on FormatException {
      throw const AssistantException(
        'The model service returned an invalid response.',
      );
    } on HttpException {
      throw const AssistantException(
        'The connection was interrupted. Please try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<String> replyStream({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
    List<ChatTurn> history = const [],
    StreamCompletion? completion,
  }) {
    final trimmed = question.trim();
    if (trimmed.isEmpty || trimmed.length > maxQuestionLength) {
      return Stream<String>.error(
        const AssistantException('Enter a question of 1–1000 characters.'),
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    // 订阅被取消（用户点「取消」/「清空对话」，或离开页面）时立刻掐断连接。
    // 不这样做的话请求会继续跑到底——用户以为停了，token 其实还在烧。
    var aborted = false;
    final controller = StreamController<String>(
      onCancel: () {
        aborted = true;
        client.close(force: true);
      },
    );
    // 所有失败分支都长一个样：固定文案经 addError 传给监听方，绝不回显 Key
    // 或上游响应体。已取消的订阅不再收事件（Dart 会直接丢弃），这里也显式跳过。
    Future<void> emitError(AssistantException error) async {
      if (!aborted && !controller.isClosed) controller.addError(error);
      if (!controller.isClosed) await controller.close();
    }

    // 异步体里逐块推进。
    () async {
      try {
        await for (final chunk in _requestStream(
          client,
          trimmed,
          context,
          references,
          history,
          completion,
        )) {
          if (!aborted && !controller.isClosed) controller.add(chunk);
        }
        if (!controller.isClosed) await controller.close();
      } on AssistantException catch (error) {
        await emitError(error);
      } on TimeoutException {
        await emitError(
          const AssistantException(
            'The model service timed out. Try again or switch to Local.',
          ),
        );
      } on SocketException {
        await emitError(
          const AssistantException(
            'Cannot connect to the model service. Check the URL and network.',
          ),
        );
      } on HandshakeException {
        await emitError(
          const AssistantException(
            'The service certificate could not be verified. Check the URL.',
          ),
        );
      } on FormatException {
        await emitError(
          const AssistantException(
            'The model service returned an invalid response.',
          ),
        );
      } on HttpException {
        await emitError(
          const AssistantException(
            'The connection was interrupted. Please try again.',
          ),
        );
      } on StateError {
        // 自己关掉连接后（取消）继续读流会抛这个：连接没了，不是上游的问题。
        await emitError(
          const AssistantException(
            'The connection was interrupted. Please try again.',
          ),
        );
      } finally {
        client.close(force: true);
      }
    }();
    return controller.stream;
  }

  /// 请求体。多轮上下文以真实的 chat message 形式插在 system 与当前问题之间。
  Map<String, dynamic> _body(
    String question,
    AssistantContext context,
    List<String> references,
    List<ChatTurn> history, {
    required bool stream,
  }) => {
    'model': model,
    'temperature': 0,
    if (stream) 'stream': true,
    'messages': [
      {
        'role': 'system',
        'content': history.isEmpty
            ? assistantSystemPrompt
            : '$assistantSystemPrompt\n$assistantHistoryNote',
      },
      for (final turn in history) {'role': turn.role, 'content': turn.text},
      {
        'role': 'user',
        'content': assistantUserPayload(
          question,
          context,
          references: references,
        ),
      },
    ],
  };

  /// 所有失败分支都只说固定文案，绝不回显 Key 或上游响应体。
  Future<String> _request(
    HttpClient client,
    String question,
    AssistantContext context,
    List<String> references,
  ) async {
    final request = await client.postUrl(endpoint).timeout(timeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.write(
      jsonEncode(_body(question, context, references, const [], stream: false)),
    );
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw AssistantException(_statusMessage(response.statusCode));
    }
    if (response.headers.contentType?.mimeType != 'application/json') {
      throw const AssistantException(
        'The model service returned an invalid response.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const AssistantException(
          'The response exceeds the receive limit. Ask in smaller parts.',
        );
      }
      bytes.addAll(chunk);
    }
    return _extractAnswer(jsonDecode(utf8.decode(bytes)));
  }

  /// 流式请求：`stream: true`。服务端返回 SSE（`text/event-stream`）时逐块解析；
  /// 少数服务端不支持流式、直接回了整段 JSON，这里兜底按单次回答返回。
  Stream<String> _requestStream(
    HttpClient client,
    String question,
    AssistantContext context,
    List<String> references,
    List<ChatTurn> history,
    StreamCompletion? completion,
  ) async* {
    final request = await client.postUrl(endpoint).timeout(timeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.write(
      jsonEncode(_body(question, context, references, history, stream: true)),
    );
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw AssistantException(_statusMessage(response.statusCode));
    }
    final contentType = response.headers.contentType?.mimeType ?? '';
    if (contentType == 'text/event-stream' ||
        contentType == 'application/x-ndjson' ||
        contentType.contains('event-stream')) {
      yield* _parseSse(response, completion);
      return;
    }
    // 不支持流式：整段 JSON 兜底。
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const AssistantException(
          'The response exceeds the receive limit. Ask in smaller parts.',
        );
      }
      bytes.addAll(chunk);
    }
    yield _extractAnswer(
      jsonDecode(utf8.decode(bytes)),
      completion: completion,
    );
  }

  /// 把 SSE 流切成「data: …」行，逐行抽 `choices[0].delta.content`。
  ///
  /// 按字节切行（换行符是 ASCII 0x0A），只对完整的一行做 UTF-8 解码，
  /// 这样 chunk 边界把某个中文多字节字符切两半也不会出乱码。
  ///
  /// 服务端正常结束会发 `data: [DONE]`。没收到它流就断了，有两种可能：服务端
  /// 中途挂了（只拿到半截），或者这个服务端本来就不发 `[DONE]`、内容其实是完整的。
  /// 两者在协议上分不出来，所以**不丢已收到的文字**，只把「没确认收完」记进
  /// [completion]，由页面在回答末尾提醒用户核对；真正连不上的错误仍由异常处理。
  Stream<String> _parseSse(
    HttpClientResponse response,
    StreamCompletion? completion,
  ) async* {
    var buffer = <int>[];
    var total = 0;
    var answerBytes = 0;
    // 按网络活动计时：心跳和 reasoning_content 都证明连接仍在工作，
    // 即使暂时没有可显示的 content，也不应触发「响应超时」。
    await for (final chunk in response.timeout(timeout)) {
      total += chunk.length;
      if (total > maxStreamBytes) {
        throw const AssistantException(
          'The response exceeds the receive limit. Ask in smaller parts.',
        );
      }
      buffer.addAll(chunk);
      var newline = buffer.indexOf(0x0A);
      while (newline >= 0) {
        if (newline > maxSseLineBytes) {
          throw const AssistantException(
            'A response packet is too large. Please try again.',
          );
        }
        final line = utf8.decode(
          buffer.sublist(0, newline),
          allowMalformed: true,
        );
        buffer = buffer.sublist(newline + 1);
        if (_isDoneLine(line)) {
          return;
        } else {
          final content = _sseDelta(line, completion);
          if (content != null && content.isNotEmpty) {
            answerBytes += utf8.encode(content).length;
            _checkAnswerSize(answerBytes);
            yield content;
          }
        }
        newline = buffer.indexOf(0x0A);
      }
      if (buffer.length > maxSseLineBytes) {
        throw const AssistantException(
          'A response packet is too large. Please try again.',
        );
      }
    }
    if (buffer.isNotEmpty) {
      final line = utf8.decode(buffer, allowMalformed: true);
      if (_isDoneLine(line)) {
        return;
      } else {
        final content = _sseDelta(line, completion);
        if (content != null && content.isNotEmpty) {
          answerBytes += utf8.encode(content).length;
          _checkAnswerSize(answerBytes);
          yield content;
        }
      }
    }
    completion?.markIncomplete();
  }

  /// 一行是不是 SSE 的结束哨兵 `data: [DONE]`。
  static bool _isDoneLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('data:')) return false;
    return trimmed.substring('data:'.length).trim() == '[DONE]';
  }

  /// 从一行 SSE 里取增量文字；不是数据行、`[DONE]` 或解析不了就返回 null。
  static String? _sseDelta(String line, StreamCompletion? completion) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('data:')) return null;
    final payload = trimmed.substring('data:'.length).trim();
    if (payload == '[DONE]') return null;
    try {
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic>) return null;
      // HTTP 200 的 SSE 也可能通过 error 事件报告失败。不能把它当作空增量
      // 忽略，否则已经收到的半截文字会被保存成成功回答；不回显上游内容。
      if (data['error'] != null) {
        throw const AssistantException(
          'The model service failed before completing the answer. Please try again.',
        );
      }
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        return null;
      }
      final choice = choices.first as Map;
      final reason = _incompleteReason(choice['finish_reason']);
      if (reason != null) completion?.markIncomplete(reason);
      final delta = choice['delta'];
      if (delta is! Map) return null;
      final content = delta['content'];
      return content is String ? content : null;
    } on FormatException {
      return null;
    }
  }

  static String _statusMessage(int statusCode) => switch (statusCode) {
    400 || 413 => 'The service rejected the request. Check the model name.',
    401 || 403 => 'Your API key is invalid or cannot access this model.',
    404 => 'Check the model service URL and model name.',
    429 => 'The service is busy or its quota is exhausted. Try again later.',
    _ => 'The model service is unavailable. Try again or switch to Local.',
  };

  static void _checkAnswerSize(int bytes) {
    if (bytes > maxAnswerBytes) {
      throw const AssistantException(
        'The answer exceeds the receive limit. Ask in smaller parts.',
      );
    }
  }

  /// 正常关闭传输与模型完整回答是两件事。输出额度耗尽时仍可能收到 [DONE]。
  static String? _incompleteReason(
    Object? finishReason,
  ) => switch (finishReason) {
    null || 'stop' => null,
    'length' =>
      'The model reached its output limit. The answer is incomplete; ask in smaller parts or retry.',
    'content_filter' =>
      'The service stopped the answer due to a content restriction. Rephrase your question or retry.',
    _ => 'The service stopped before completing the answer. Please try again.',
  };

  static String _extractAnswer(dynamic data, {StreamCompletion? completion}) {
    if (data is! Map<String, dynamic>) {
      throw const AssistantException(
        'The model service returned an invalid response.',
      );
    }
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const AssistantException('The model service returned no answer.');
    }
    final message = (choices.first as Map)['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const AssistantException('The model service returned no text.');
    }
    _checkAnswerSize(utf8.encode(content).length);
    final reason = _incompleteReason((choices.first as Map)['finish_reason']);
    if (reason != null) {
      if (completion != null) {
        completion.markIncomplete(reason);
      } else {
        return '${content.trim()}\n\n（$reason）';
      }
    }
    return content.trim();
  }
}
