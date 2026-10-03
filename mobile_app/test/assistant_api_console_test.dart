import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_api_console.dart';
import 'package:medication_device_app/assistant/assistant_credentials.dart';
import 'package:medication_device_app/assistant/assistant_page.dart';
import 'package:medication_device_app/assistant/assistant_service.dart';

/// 内存实现，避免测试依赖平台的安全存储通道。
class _MemoryStore implements AssistantCredentialsStore {
  _MemoryStore([this.state = AssistantCredentialState.empty]);

  AssistantCredentialState state;
  int saves = 0;
  int clears = 0;

  @override
  Future<AssistantCredentialState> load() async => state;

  @override
  Future<void> save(AssistantCredentialState next) async {
    saves++;
    state = next;
  }

  @override
  Future<void> clear() async {
    clears++;
    state = AssistantCredentialState.empty;
  }
}

/// 系统安全存储不可用的情况：必须报错，不能假装存下了。
class _FailingStore implements AssistantCredentialsStore {
  @override
  Future<AssistantCredentialState> load() async => const AssistantCredentialState(
        profiles: [_gateway],
        selectedId: 'g1',
      );

  @override
  Future<void> save(AssistantCredentialState state) async =>
      throw StateError('keystore unavailable');

  @override
  Future<void> clear() async => throw StateError('keystore unavailable');
}

const _gateway = AssistantProfile(
  id: 'g1',
  name: '团队网关',
  mode: OnlineAssistantMode.gateway,
  endpoint: 'https://assistant.example.com/v1/assistant/chat',
  accessToken: 'gateway-code',
);

const _ownModel = AssistantProfile(
  id: 'm1',
  name: 'DeepSeek',
  mode: OnlineAssistantMode.ownModel,
  baseUrl: 'https://api.deepseek.com/v1',
  apiKey: 'private-key-1234',
  model: 'deepseek-chat',
);

/// 对话框内容比默认视口高，放大视口免得控件落在可视区外点不到。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 按助手页的真实方式打开控制台：push 成一条路由，pop 才是安全的。
Future<void> openConsole(
  WidgetTester tester,
  AssistantCredentialsStore store, {
  void Function(AssistantService?)? onResult,
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              // 不要写成 onResult?.call(await showDialog(...))：?. 会短路，
              // onResult 为空时参数不求值，showDialog 根本不会被调用，对话框也就不出现。
              onPressed: () async {
                final service = await showDialog<AssistantService>(
                  context: context,
                  builder: (_) => AssistantApiConsole(store: store),
                );
                onResult?.call(service);
              },
              child: const Text('打开控制台'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开控制台'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空列表给引导，添加后出现在列表并成为当前使用', (tester) async {
    final store = _MemoryStore();
    await openConsole(tester, store);
    expect(find.textContaining('还没有保存任何 API'), findsOneWidget);

    await tester.tap(find.text('添加新的 API'));
    await tester.pumpAndSettle();
    expect(find.text('添加 API'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('profile-name')), '我的模型');
    await tester.enterText(
      find.byKey(const Key('model-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(find.byKey(const Key('model-api-key')), 'k');
    await tester.enterText(find.byKey(const Key('model-name')), 'my-model');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(store.saves, 1);
    expect(store.state.profiles, hasLength(1));
    expect(store.state.selectedProfile?.name, '我的模型');
    expect(find.text('我的模型'), findsOneWidget);
    expect(find.text('当前使用'), findsOneWidget);
    expect(find.textContaining('还没有保存任何 API'), findsNothing);
  });

  testWidgets('点「使用」切到在线，并把选中项记下来', (tester) async {
    AssistantService? popped;
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_gateway]),
    );
    await openConsole(tester, store, onResult: (service) => popped = service);

    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.isRemote, isTrue);
    // 下次打开助手页「点一下切在线」就靠它。
    expect(store.state.selectedId, 'g1');
  });

  testWidgets('编辑会预填并改回列表，仍然是同一条配置', (tester) async {
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_ownModel], selectedId: 'm1'),
    );
    await openConsole(tester, store);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('修改 API'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model-base-url')))
          .controller
          ?.text,
      'https://api.deepseek.com/v1',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model-name')))
          .controller
          ?.text,
      'deepseek-chat',
    );

    await tester.enterText(find.byKey(const Key('profile-name')), '换成通义');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 改的是同一条，不是又加了一条。
    expect(store.state.profiles, hasLength(1));
    expect(store.state.profiles.single.id, 'm1');
    expect(find.text('换成通义'), findsOneWidget);
  });

  testWidgets('删除要二次确认，删掉当前使用的会清空选中', (tester) async {
    final store = _MemoryStore(
      const AssistantCredentialState(
        profiles: [_gateway, _ownModel],
        selectedId: 'g1',
      ),
    );
    await openConsole(tester, store);

    // 取消不删。
    await tester.tap(find.widgetWithText(TextButton, '删除').first);
    await tester.pumpAndSettle();
    expect(find.text('删除这条 API？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.state.profiles, hasLength(2));
    expect(store.saves, 0);

    // 确认才删；删掉的正是选中项，选中要一起清空。
    await tester.tap(find.widgetWithText(TextButton, '删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(store.state.profiles, hasLength(1));
    expect(store.state.profiles.single.id, 'm1');
    expect(store.state.selectedId, isNull);
  });

  testWidgets('安全存储写不进去时明确报错，不假装已经切换', (tester) async {
    AssistantService? popped;
    await openConsole(tester, _FailingStore(), onResult: (s) => popped = s);

    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法写入系统安全存储'), findsOneWidget);
    expect(popped, isNull);
    expect(find.text('使用'), findsOneWidget); // 控制台还开着，用户可以重试
  });

  testWidgets('列表只显示打码后的凭据', (tester) async {
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_ownModel], selectedId: 'm1'),
    );
    await openConsole(tester, store);

    expect(find.textContaining('private-key-1234'), findsNothing);
    expect(find.textContaining('••••••1234'), findsOneWidget);
  });

  testWidgets('助手页点一下「在线」就直接切换，不再弹设置页', (tester) async {
    _useTallViewport(tester);
    final store = _MemoryStore(
      const AssistantCredentialState(profiles: [_gateway], selectedId: 'g1'),
    );
    await tester.pumpWidget(MaterialApp(home: AssistantPage(store: store)));
    expect(find.textContaining('已启用在线助手'), findsNothing);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    expect(find.text('管理 API'), findsNothing);
    expect(find.textContaining('已启用在线助手'), findsOneWidget);
    // 在线时必须随时看得到发送边界。
    expect(find.textContaining('不发送原始记录、设备标识或历史对话'), findsOneWidget);

    // 回本地同样是一步。
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    expect(find.text('已切回本地摘要，不联网。'), findsOneWidget);
    expect(find.textContaining('不发送原始记录、设备标识或历史对话'), findsNothing);
  });

  testWidgets('没有配置过 API 时，点「在线」会打开控制台引导', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(
      MaterialApp(home: AssistantPage(store: _MemoryStore())),
    );
    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    expect(find.text('管理 API'), findsOneWidget);
    expect(find.textContaining('还没有保存任何 API'), findsOneWidget);
  });
}
