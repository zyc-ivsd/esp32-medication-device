import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_exception.dart';
import 'package:medication_device_app/assistant/assistant_provider.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/providers/direct_llm_assistant_provider.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  const context = AssistantContext(
    todayCount: 2,
    last7DaysCount: 8,
    isDemo: true,
    totalCount: 21,
    dailyCounts: [0, 1, 0, 2, 0, 0, 5],
  );

  DirectLlmAssistantProvider providerFor(String baseUrl) =>
      DirectLlmAssistantProvider(
        baseUrl: baseUrl,
        apiKey: 'user-private-key',
        model: 'user-model',
      );

  test('only https, or explicit loopback http, is accepted', () {
    for (final address in [
      'http://example.com/v1',
      'api.deepseek.com/v1',
      'https://token@example.com/v1',
      'https://example.com/v1?key=secret',
      'https://example.com/v1#fragment',
    ]) {
      expect(
        () => DirectLlmAssistantProvider(
          baseUrl: address,
          apiKey: 'k',
          model: 'm',
        ),
        throwsA(isA<AssistantException>()),
      );
    }
    expect(
      () => DirectLlmAssistantProvider(
        baseUrl: 'http://127.0.0.1:11434/v1',
        apiKey: 'k',
        model: 'm',
        allowLocalHttp: false,
      ),
      throwsA(isA<AssistantException>()),
    );
  });

  test('the chat completions path is appended exactly once', () {
    expect(
      providerFor('https://api.example.com/v1/').endpoint.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(
      providerFor('https://api.example.com/v1').endpoint.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(
      providerFor('https://api.example.com/v1/chat/completions')
          .endpoint
          .toString(),
      'https://api.example.com/v1/chat/completions',
    );
  });

  Future<void> withServer(
    Future<void> Function(HttpRequest) handler,
    Future<void> Function(String) use,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) => unawaited(handler(request)));
    try {
      // Widget binding installs a fake HTTP client globally; these contract
      // tests intentionally use a real loopback socket in this zone only.
      await HttpOverrides.runWithHttpOverrides(
        () => use('http://127.0.0.1:${server.port}/v1'),
        _LoopbackHttpOverrides(),
      );
    } finally {
      await server.close(force: true);
      await subscription.cancel();
    }
  }

  test('the request carries the user key and the answer comes back trimmed',
      () async {
    await withServer(
      (request) async {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer user-private-key',
        );
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(data['model'], 'user-model');
        expect(data['temperature'], 0);
        final messages = data['messages'] as List;
        expect(messages, hasLength(2));
        expect((messages[0] as Map)['role'], 'system');
        expect((messages[0] as Map)['content'], contains('不要诊断'));
        expect((messages[1] as Map)['role'], 'user');
        expect(
          jsonDecode((messages[1] as Map)['content'] as String)['context'],
          context.toJson(),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '  近 7 天共 8 次使用动作。  '},
              },
            ],
          }),
        );
        await request.response.close();
      },
      (baseUrl) async {
        final answer = await providerFor(baseUrl)
            .reply(question: '最近怎么样？', context: context);
        expect(answer, '近 7 天共 8 次使用动作。');
      },
    );
  });

  test('failures never leak the key or the upstream body', () async {
    for (final status in [400, 401, 403, 404, 429, 500]) {
      await withServer(
        (request) async {
          request.response.statusCode = status;
          request.response.write('echo-of-private-key user-private-key');
          await request.response.close();
        },
        (baseUrl) async {
          try {
            await providerFor(baseUrl)
                .reply(question: '次数？', context: context);
            fail('Expected a sanitized failure for $status');
          } on AssistantException catch (error) {
            expect(error.message, isNot(contains('user-private-key')));
            expect(error.message, isNot(contains('echo-of-private-key')));
          }
        },
      );
    }
  });

  test('empty credentials are rejected when the provider is built', () {
    expect(
      () => DirectLlmAssistantProvider(
        baseUrl: 'https://api.example.com/v1',
        apiKey: '   ',
        model: 'm',
      ),
      throwsA(
        isA<AssistantException>().having(
          (error) => error.message,
          'message',
          contains('API Key'),
        ),
      ),
    );
    expect(
      () => DirectLlmAssistantProvider(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'k',
        model: '  ',
      ),
      throwsA(
        isA<AssistantException>().having(
          (error) => error.message,
          'message',
          contains('模型名称'),
        ),
      ),
    );
  });

  test('malformed, empty and oversized answers fail without a fallback',
      () async {
    for (final body in [
      'not json',
      '{"choices":[]}',
      '{"choices":[{"message":{"content":"   "}}]}',
      jsonEncode({
        'choices': [
          {
            'message': {'content': 'x' * 66000},
          },
        ],
      }),
    ]) {
      await withServer(
        (request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(body);
          await request.response.close();
        },
        (baseUrl) async {
          await expectLater(
            providerFor(baseUrl).reply(question: '次数？', context: context),
            throwsA(isA<AssistantException>()),
          );
        },
      );
    }
  });

  test('streaming parses SSE data lines into ordered chunks', () async {
    await withServer(
      (request) async {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(data['stream'], true);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write('data: {"choices":[{"delta":{"content":"近 7 天"}}]}\n\n');
        request.response.write('data: {"choices":[{"delta":{"content":"共 8 次。"}}]}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      },
      (baseUrl) async {
        final chunks = await providerFor(baseUrl)
            .replyStream(question: '最近怎么样？', context: context)
            .toList();
        expect(chunks, ['近 7 天', '共 8 次。']);
      },
    );
  });

  test('SSE 流没收到 [DONE]：留着已收到的内容，只标记「没确认收完」', () async {
    await withServer(
      (request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"半截回答"}}]}\n\n',
        );
        await request.response.close();
      },
      (baseUrl) async {
        // 不发 [DONE] 的服务端不少见，内容往往是完整的，所以不丢回答……
        final completion = StreamCompletion();
        final chunks = await providerFor(baseUrl)
            .replyStream(
              question: '最近怎么样？',
              context: context,
              completion: completion,
            )
            .toList();
        expect(chunks, ['半截回答']);
        // ……但也没法确认收全，要用这个标记告诉页面补提醒。
        expect(completion.isComplete, isFalse);
      },
    );
  });

  test('收到 [DONE] 的回答标记为已收完', () async {
    await withServer(
      (request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write('data: {"choices":[{"delta":{"content":"完整"}}]}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      },
      (baseUrl) async {
        final completion = StreamCompletion();
        final chunks = await providerFor(baseUrl)
            .replyStream(
              question: '最近怎么样？',
              context: context,
              completion: completion,
            )
            .toList();
        expect(chunks, ['完整']);
        expect(completion.isComplete, isTrue);
      },
    );
  });

  test('取消订阅会掐断连接，服务端立刻看到连接断开', () async {
    final disconnected = Completer<void>();
    void signalDisconnect() {
      if (!disconnected.isCompleted) disconnected.complete();
    }

    // 这条**故意不用 HttpServer**。客户端断连之后，服务端的 `HttpResponse`
    // 是察觉不到的：`flush()` 在没有待刷数据时是个空操作（`_StreamSinkImpl.flush`
    // 在 `_controllerInstance == null` 时直接 `return Future.value(this)`），
    // 而 `done` 要等 `close()` 才完成——而循环里从来不会 close。于是「服务端还在
    // 不在写」在 HttpServer 这一层根本观察不到，那种写法只会一直等到超时，客户端
    // 怎么改都过不了。
    //
    // 所以这里直接架一个裸 Socket 手写 SSE 响应：客户端一销毁连接，服务端这侧
    // 的读取立刻拿到 EOF（`onDone`）或错误，这是内核给的信号，绕不过去。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.listen(
        (_) {}, // 请求体不关心，但必须一直读着，否则收不到对端的 FIN。
        onDone: signalDisconnect,
        onError: (Object _) => signalDisconnect(),
      );
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/event-stream\r\n'
        'Transfer-Encoding: chunked\r\n'
        '\r\n',
      );
      void frame(String text) {
        final bytes = utf8.encode(text);
        socket.add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'));
        socket.add(bytes);
        socket.add(const [0x0d, 0x0a]);
      }

      frame('data: {"choices":[{"delta":{"content":"第一块"}}]}\n\n');
      unawaited(() async {
        while (!disconnected.isCompleted) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          try {
            frame('data: {"choices":[{"delta":{"content":"继续"}}]}\n\n');
            await socket.flush();
          } catch (_) {
            signalDisconnect();
            return;
          }
        }
      }());
    });

    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        final subscription = providerFor('http://127.0.0.1:${server.port}/v1')
            .replyStream(question: '最近怎么样？', context: context)
            .listen((_) {});
        // 第一块到了就说明连接是活的——取消之前得先确认这一点，否则这条测试
        // 什么也没证明。
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(disconnected.isCompleted, isFalse);
        await subscription.cancel();
        // 取消没生效的话，连接会被服务端一直喂到测试结束——超时即失败。
        await disconnected.future.timeout(const Duration(seconds: 5));
      }, _LoopbackHttpOverrides());
    } finally {
      await server.close();
    }
  });

  for (final sendPartial in [false, true]) {
    for (final sendDone in [false, true]) {
      test(
        'SSE error fails safely (partial=$sendPartial, DONE=$sendDone)',
        () async {
          await withServer(
            (request) async {
              await request.drain<void>();
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
                charset: 'utf-8',
              );
              if (sendPartial) {
                request.response.write(
                  'data: {"choices":[{"delta":{"content":"半截回答"}}]}\n\n',
                );
              }
              request.response.write(
                'data: ${jsonEncode({
                  'error': {'message': 'private user-private-key', 'type': 'server_error'},
                })}\n\n',
              );
              if (sendDone) request.response.write('data: [DONE]\n\n');
              await request.response.close();
            },
            (baseUrl) async {
              final completion = StreamCompletion();
              final received = <String>[];
              try {
                await for (final delta in providerFor(baseUrl).replyStream(
                  question: '最近怎么样？',
                  context: context,
                  completion: completion,
                )) {
                  received.add(delta);
                }
                fail(
                  'An explicit upstream error must not complete successfully.',
                );
              } on AssistantException catch (error) {
                expect(error.message, contains('回答未完成'));
                expect(error.message, isNot(contains('user-private-key')));
                expect(error.message, isNot(contains('private')));
                expect(received, sendPartial ? ['半截回答'] : isEmpty);
              }
            },
          );
        },
      );
    }
  }

  test('streaming falls back to one chunk when the server returns plain JSON',
      () async {
    await withServer(
      (request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '近 7 天共 8 次使用动作。'},
              },
            ],
          }),
        );
        await request.response.close();
      },
      (baseUrl) async {
        final chunks = await providerFor(baseUrl)
            .replyStream(question: '最近怎么样？', context: context)
            .toList();
        expect(chunks, ['近 7 天共 8 次使用动作。']);
      },
    );
  });

  test('streaming sends multi-turn history as messages before the question',
      () async {
    await withServer(
      (request) async {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final messages = data['messages'] as List;
        expect(messages, hasLength(4));
        expect((messages[0] as Map)['role'], 'system');
        expect((messages[0] as Map)['content'], contains('更早的几轮问答'));
        expect((messages[1] as Map), {'role': 'user', 'content': '上一条问题'});
        expect((messages[2] as Map), {
          'role': 'assistant',
          'content': '上一条回答',
        });
        expect((messages[3] as Map)['role'], 'user');
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      },
      (baseUrl) async {
        await providerFor(baseUrl)
            .replyStream(
              question: '那今天呢？',
              context: context,
              history: const [
                (role: 'user', text: '上一条问题'),
                (role: 'assistant', text: '上一条回答'),
              ],
            )
            .drain<void>();
      },
    );
  });
}
