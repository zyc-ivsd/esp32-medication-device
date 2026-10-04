import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../assistant_exception.dart';
import '../assistant_provider.dart';
import '../models/assistant_context.dart';

/// Our HTTP gateway contract, not an HTTP API provided by xiaozhi itself.
class GatewayAssistantProvider implements AssistantProvider {
  GatewayAssistantProvider({
    required String endpoint,
    this.accessToken = '',
    this.timeout = const Duration(seconds: 55),
    bool allowLocalHttp = kDebugMode,
  }) : endpoint = validateEndpoint(endpoint, allowLocalHttp: allowLocalHttp);

  final Uri endpoint;
  final String accessToken;
  final Duration timeout;
  static const maxQuestionLength = 1000;
  static const maxResponseBytes = 64 * 1024;

  static Uri validateEndpoint(
    String value, {
    bool allowLocalHttp = kDebugMode,
  }) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.endsWith('/v1/assistant/chat')) {
      throw const AssistantException(
        'Enter a complete gateway URL ending in /v1/assistant/chat.',
      );
    }
    final localHttp =
        allowLocalHttp &&
        uri.scheme == 'http' &&
        const ['127.0.0.1', 'localhost', '10.0.2.2'].contains(uri.host);
    if (uri.scheme != 'https' && !localHttp) {
      throw const AssistantException(
        'The online service requires HTTPS. Debug builds allow HTTP only on localhost.',
      );
    }
    return uri;
  }

  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async {
    // 网关已作历史保留，不再扩展检索，references 忽略。
    final trimmed = question.trim();
    if (trimmed.isEmpty || trimmed.length > maxQuestionLength) {
      throw const AssistantException('Enter a question of 1–1000 characters.');
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _request(client, trimmed, context).timeout(timeout);
    } on AssistantException {
      rethrow;
    } on TimeoutException {
      throw const AssistantException(
        'The online assistant timed out. Try again or switch to Local.',
      );
    } on SocketException {
      throw const AssistantException(
        'Cannot connect to the online assistant. Check the URL and network.',
      );
    } on HandshakeException {
      throw const AssistantException(
        'The service certificate could not be verified. Contact the service administrator.',
      );
    } on FormatException {
      throw const AssistantException(
        'The online assistant returned an invalid response. Contact the service administrator.',
      );
    } on HttpException {
      throw const AssistantException(
        'The online connection was interrupted. Please try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 只从失败响应里取 `request_id` 这一个字段。
  ///
  /// 错误响应体可能带上游内部信息，所以绝不整体回显；读不出来就返回 null，
  /// 用户看到的仍然是原来那句固定文案。
  static Future<String?> _requestIdOf(HttpClientResponse response) async {
    try {
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 2048) return null;
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      final id = data is Map ? data['request_id'] : null;
      return id is String && id.isNotEmpty && id.length <= 64 ? id : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _request(
    HttpClient client,
    String question,
    AssistantContext context,
  ) async {
    final request = await client.postUrl(endpoint);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (accessToken.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
    }
    request.write(
      jsonEncode({
        'schema_version': 1,
        'question': question,
        'context': context.toJson(),
      }),
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      // 失败时把请求编号一起带给用户：他能凭这个报问题，而不必交出问题原文或摘要。
      final requestId = await _requestIdOf(response);
      final message = switch (response.statusCode) {
        401 || 403 =>
          'The gateway access code is invalid or expired. Update your configuration.',
        429 => 'The assistant is busy. Please try again later.',
        504 => 'The assistant service timed out. Please try again later.',
        400 || 413 =>
          'The service rejected the question or record summary. Update the app and retry.',
        _ =>
          'The online assistant is unavailable. Try again or switch to Local.',
      };
      throw AssistantException(
        requestId == null ? message : '$message (request $requestId)',
        requestId: requestId,
      );
    }
    if (response.headers.contentType?.mimeType != 'application/json') {
      throw const AssistantException(
        'The online assistant returned an invalid response. Contact the service administrator.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const AssistantException(
          'The online answer exceeds the receive limit. Ask in smaller parts.',
        );
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['schema_version'] != 1 ||
        data['answer'] is! String ||
        (data['answer'] as String).trim().isEmpty ||
        !const ['mock', 'xiaozhi', 'llm'].contains(data['provider'])) {
      throw const AssistantException(
        'The online assistant returned an invalid response. Contact the service administrator.',
      );
    }
    final answer = (data['answer'] as String).trim();
    return data['provider'] == 'mock'
        ? '[Gateway test response]\n$answer'
        : answer;
  }
}
