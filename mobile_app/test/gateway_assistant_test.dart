import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_exception.dart';
import 'package:medication_device_app/assistant/assistant_page.dart';
import 'package:medication_device_app/assistant/assistant_provider.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';
import 'package:medication_device_app/assistant/assistant_settings_dialog.dart';
import 'package:medication_device_app/assistant/models/assistant_context.dart';
import 'package:medication_device_app/assistant/providers/gateway_assistant_provider.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

class _RemoteFailure implements AssistantProvider {
  @override
  Future<String> reply({
    required String question,
    required AssistantContext context,
    List<String> references = const [],
  }) async => throw const AssistantException(
    'The online assistant timed out. Try again or switch to Local.',
  );
}

/// 设置表单比默认 600 视口高，内容会长在弹窗的可滚动区里；
/// 放大视口免得勾选框落在可视区外点不到。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  const context = AssistantContext(
    todayCount: 2,
    last7DaysCount: 8,
    totalCount: 21,
    dailyCounts: [0, 1, 0, 2, 0, 0, 5],
  );

  test('HTTPS is required outside explicit loopback debug transport', () {
    for (final address in [
      'http://example.com/v1/assistant/chat',
      'https://secret@example.com/v1/assistant/chat',
      'https://example.com/v1/assistant/chat?token=secret',
      'wss://example.com/xiaozhi/v1/',
    ]) {
      expect(
        () => GatewayAssistantProvider(endpoint: address),
        throwsA(isA<AssistantException>()),
      );
    }
    expect(
      () => GatewayAssistantProvider(
        endpoint: 'http://127.0.0.1:8787/v1/assistant/chat',
        allowLocalHttp: false,
      ),
      throwsA(isA<AssistantException>()),
    );
  });

  Future<void> withServer(
    Future<void> Function(HttpRequest) handler,
    Future<void> Function(String) use,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen(
      (request) => unawaited(handler(request)),
    );
    try {
      // Widget binding installs a fake HTTP client globally. These contract
      // tests intentionally use a real loopback socket in this zone only.
      await HttpOverrides.runWithHttpOverrides(
        () => use('http://127.0.0.1:${server.port}/v1/assistant/chat'),
        _LoopbackHttpOverrides(),
      );
    } finally {
      await server.close(force: true);
      await subscription.cancel();
    }
  }

  test(
    'wire request contains fresh summary and auth, response is explicitly marked mock',
    () async {
      await withServer(
        (request) async {
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer gateway-code',
          );
          final data =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(data.keys.toSet(), {'schema_version', 'question', 'context'});
          expect(data['context'], context.toJson());
          final wireContext = data['context'] as Map;
          expect(wireContext['daily_counts'], [0, 1, 0, 2, 0, 0, 5]);
          expect(wireContext['total_count'], 21);
          // The gateway rejects summaries whose series contradicts the total.
          expect(
            (wireContext['daily_counts'] as List).fold<int>(
              0,
              (sum, count) => sum + (count as int),
            ),
            wireContext['last_7_days_count'],
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'schema_version': 1,
              'answer': '演示回复',
              'provider': 'mock',
            }),
          );
          await request.response.close();
        },
        (endpoint) async {
          final provider = GatewayAssistantProvider(
            endpoint: endpoint,
            accessToken: 'gateway-code',
          );
          final answer = await provider.reply(
            question: '最近记录？',
            context: context,
          );
          expect(answer, contains('Gateway test response'));
          expect(answer, contains('演示回复'));
        },
      );
    },
  );

  test('an llm provider answer is shown without a demo prefix', () async {
    await withServer(
      (request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'schema_version': 1,
            'answer': '近 7 天共 8 次使用动作，有 2 天没有设备记录。',
            'provider': 'llm',
          }),
        );
        await request.response.close();
      },
      (endpoint) async {
        final answer = await GatewayAssistantProvider(
          endpoint: endpoint,
        ).reply(question: 'What needs attention?', context: context);
        expect(answer, '近 7 天共 8 次使用动作，有 2 天没有设备记录。');
        expect(answer, isNot(contains('Gateway test response')));
      },
    );
  });

  test(
    'HTTP auth errors do not expose upstream payloads and redirects are not followed',
    () async {
      for (final status in [401, 302, 502]) {
        var requests = 0;
        await withServer(
          (request) async {
            requests++;
            request.response.statusCode = status;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '/another-path',
            );
            request.response.write('private-upstream-token');
            await request.response.close();
          },
          (endpoint) async {
            try {
              await GatewayAssistantProvider(
                endpoint: endpoint,
              ).reply(question: '次数？', context: context);
              fail('Expected sanitized failure');
            } on AssistantException catch (error) {
              expect(error.message, isNot(contains('private-upstream-token')));
            }
            expect(requests, 1);
          },
        );
      }
    },
  );

  test(
    'failures surface the gateway request id but not the error body',
    () async {
      await withServer(
        (request) async {
          request.response.statusCode = 502;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'error': {
                'code': 'upstream_protocol',
                'message': 'private-upstream-detail',
              },
              'request_id': 'abcdef0123456789abcdef0123456789',
            }),
          );
          await request.response.close();
        },
        (endpoint) async {
          try {
            await GatewayAssistantProvider(
              endpoint: endpoint,
            ).reply(question: '次数？', context: context);
            fail('Expected a sanitized failure');
          } on AssistantException catch (error) {
            // 用户能凭编号报问题，但看不到上游自己的说明。
            expect(error.requestId, 'abcdef0123456789abcdef0123456789');
            expect(error.message, contains('request'));
            expect(error.message, isNot(contains('private-upstream-detail')));
            expect(error.message, isNot(contains('upstream_protocol')));
          }
        },
      );
    },
  );

  test('a failure without a request id keeps the plain message', () async {
    await withServer(
      (request) async {
        // 没有 request_id，甚至根本不是 JSON。
        request.response.statusCode = 500;
        request.response.write('<html>gateway error</html>');
        await request.response.close();
      },
      (endpoint) async {
        try {
          await GatewayAssistantProvider(
            endpoint: endpoint,
          ).reply(question: '次数？', context: context);
          fail('Expected a sanitized failure');
        } on AssistantException catch (error) {
          expect(error.requestId, isNull);
          expect(
            error.message,
            'The online assistant is unavailable. Try again or switch to Local.',
          );
        }
      },
    );
  });

  test(
    'invalid, empty and oversized JSON responses fail without a local fallback',
    () async {
      for (final body in [
        'not json',
        '{"answer":""}',
        jsonEncode({
          'schema_version': 1,
          'provider': 'xiaozhi',
          'answer': 'x' * 66000,
        }),
      ]) {
        await withServer(
          (request) async {
            request.response.headers.contentType = ContentType.json;
            request.response.write(body);
            await request.response.close();
          },
          (endpoint) async {
            await expectLater(
              GatewayAssistantProvider(
                endpoint: endpoint,
              ).reply(question: '次数？', context: context),
              throwsA(isA<AssistantException>()),
            );
          },
        );
      }
    },
  );

  test('total timeout covers a server that never responds', () async {
    await withServer((request) async {}, (endpoint) async {
      await expectLater(
        GatewayAssistantProvider(
          endpoint: endpoint,
          timeout: const Duration(milliseconds: 70),
        ).reply(question: '次数？', context: context),
        throwsA(
          isA<AssistantException>().having(
            (error) => error.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });
  });

  testWidgets('online setup requires consent and a complete config', (
    tester,
  ) async {
    _useTallViewport(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AssistantSettingsDialog())),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // 地址不完整时就地报错，不会存下一条用不了的配置。
    //
    // 对话框现在只收「我自己的模型」——网关模式已从表单移除（网关本身也已废弃），
    // 所以这里是模型服务地址的校验消息，不再是「请输入完整的网关地址」。
    // 空地址在构造函数的初始化列表里就被拦下，早于 API Key / 模型名的检查。
    expect(
      find.textContaining('Enter a complete model service URL'),
      findsOneWidget,
    );
  });

  testWidgets(
    'remote errors remain visible and never masquerade as local answers',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantPage(
            service: AssistantService(
              provider: _RemoteFailure(),
              isRemote: true,
            ),
          ),
        ),
      );
      expect(find.text('Online'), findsOneWidget);
      // 在线时必须随时看得到发送边界，而不是只在设置页里写一次。
      expect(
        find.textContaining(
          'Raw records, device identifiers and chat history are not sent',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(ActionChip, 'How many uses today?'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The online assistant timed out'),
        findsOneWidget,
      );
      // 分段控件里选「本地」即切回本地摘要。
      await tester.tap(find.text('Local'));
      await tester.pumpAndSettle();
      expect(
        find.text('Switched to Local. No network connection is used.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Raw records, device identifiers and chat history are not sent',
        ),
        findsNothing,
      );
    },
  );
}
