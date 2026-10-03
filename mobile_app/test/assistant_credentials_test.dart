import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_credentials.dart';
import 'package:medication_device_app/assistant/providers/direct_llm_assistant_provider.dart';
import 'package:medication_device_app/assistant/providers/gateway_assistant_provider.dart';

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

/// 读档就失败（平台通道不可用、解密失败）的存储。
class _UnreadableStore implements AssistantCredentialsStore {
  @override
  Future<AssistantCredentialState> load() async =>
      throw StateError('keystore unavailable');

  @override
  Future<void> save(AssistantCredentialState state) async {}

  @override
  Future<void> clear() async {}
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

void main() {
  test('档案可以完整往返序列化', () {
    final restored = AssistantProfile.fromJson(_ownModel.toJson());
    expect(restored?.id, 'm1');
    expect(restored?.name, 'DeepSeek');
    expect(restored?.mode, OnlineAssistantMode.ownModel);
    expect(restored?.baseUrl, 'https://api.deepseek.com/v1');
    expect(restored?.apiKey, 'private-key-1234');
    expect(restored?.model, 'deepseek-chat');
  });

  test('整包状态（列表 + 选中项）可以往返序列化', () {
    const state = AssistantCredentialState(
      profiles: [_gateway, _ownModel],
      selectedId: 'm1',
    );
    final restored = AssistantCredentialState.fromJson(state.toJson());
    expect(restored.profiles, hasLength(2));
    expect(restored.selectedId, 'm1');
    expect(restored.selectedProfile?.name, 'DeepSeek');
  });

  test('损坏或旧格式的存档按「没有配置过」处理', () {
    for (final broken in <Object?>[
      null,
      'not-a-map',
      <String, dynamic>{},
      {'profiles': 'not-a-list'},
    ]) {
      final state = AssistantCredentialState.fromJson(broken);
      expect(state.profiles, isEmpty, reason: '$broken');
      expect(state.selectedId, isNull, reason: '$broken');
      expect(state.selectedProfile, isNull, reason: '$broken');
    }
    for (final broken in <Object?>[
      null,
      'not-a-map',
      <String, dynamic>{},
      {'mode': 'unknown-mode'},
      {'mode': 3},
    ]) {
      expect(AssistantProfile.fromJson(broken), isNull, reason: '$broken');
    }
  });

  test('单条坏掉只跳过它，其余配置仍然可用', () {
    final state = AssistantCredentialState.fromJson({
      'selected_id': 'g1',
      'profiles': [
        {'mode': 'unknown-mode'},
        _gateway.toJson(),
      ],
    });
    expect(state.profiles, hasLength(1));
    expect(state.selectedProfile?.id, 'g1');
  });

  test('上一版的单条存档能认出来，并给出稳定的 id', () {
    // v1 的字段：没有 id、没有 name。
    final legacy = AssistantProfile.fromJson({
      'mode': 'ownModel',
      'base_url': 'https://api.deepseek.com/v1',
      'api_key': 'private-key',
      'model': 'deepseek-chat',
    });
    expect(legacy, isNotNull);
    expect(legacy!.id, isNotEmpty);
    expect(legacy.name, isEmpty);
    expect(legacy.autoName(), 'deepseek-chat');
    // 同一个存档解析两次得到同一个 id：选中项靠它，不能每次都变。
    final again = AssistantProfile.fromJson({
      'mode': 'ownModel',
      'base_url': 'https://api.deepseek.com/v1',
      'api_key': 'private-key',
      'model': 'deepseek-chat',
    });
    expect(again?.id, legacy.id);
  });

  test('选中 id 对不上任何一条时按「没有选中」处理', () {
    const state = AssistantCredentialState(
      profiles: [_gateway],
      selectedId: 'gone',
    );
    expect(state.selectedProfile, isNull);
  });

  test('列表里只显示打码后的凭据', () {
    expect(_ownModel.maskedSecret, '••••••1234');
    expect(_ownModel.maskedSecret, isNot(contains('private-key')));
    expect(_gateway.maskedSecret, '••••••code');
    const short = AssistantProfile(
      id: 's',
      name: '短',
      mode: OnlineAssistantMode.ownModel,
      apiKey: 'abcd',
    );
    expect(short.maskedSecret, '••••');
    const empty = AssistantProfile(
      id: 'e',
      name: '空',
      mode: OnlineAssistantMode.ownModel,
    );
    expect(empty.maskedSecret, '未填写');
  });

  test('没填名字时用模式或模型名兜底，withName 只换名字', () {
    const ownModelNoName = AssistantProfile(
      id: 'x',
      name: '',
      mode: OnlineAssistantMode.ownModel,
      model: 'qwen-plus',
    );
    expect(ownModelNoName.autoName(), 'qwen-plus');
    const gatewayNoName = AssistantProfile(
      id: 'y',
      name: '',
      mode: OnlineAssistantMode.gateway,
    );
    expect(gatewayNoName.autoName(), '团队网关');
    const noModel = AssistantProfile(
      id: 'z',
      name: '',
      mode: OnlineAssistantMode.ownModel,
    );
    expect(noModel.autoName(), '我的模型');

    final renamed = ownModelNoName.withName('通义');
    expect(renamed.name, '通义');
    expect(renamed.id, 'x');
    expect(renamed.model, 'qwen-plus');
  });

  test('按选中项构造对应的 provider', () async {
    final fromOwnModel = await buildSelectedProvider(
      _MemoryStore(
        const AssistantCredentialState(
          profiles: [_ownModel],
          selectedId: 'm1',
        ),
      ),
    );
    expect(fromOwnModel, isA<DirectLlmAssistantProvider>());

    final fromGateway = await buildSelectedProvider(
      _MemoryStore(
        const AssistantCredentialState(profiles: [_gateway], selectedId: 'g1'),
      ),
    );
    expect(fromGateway, isA<GatewayAssistantProvider>());
  });

  test('没有选中项或配置不完整时返回 null，不抛异常', () async {
    // 没配置过。
    expect(await buildSelectedProvider(_MemoryStore()), isNull);
    // 有列表但没有选中项。
    expect(
      await buildSelectedProvider(
        _MemoryStore(const AssistantCredentialState(profiles: [_gateway])),
      ),
      isNull,
    );
    // 选中了但缺 Key：切换路径不能把构造异常抛给页面。
    const incomplete = AssistantProfile(
      id: 'bad',
      name: '缺 Key',
      mode: OnlineAssistantMode.ownModel,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
    );
    final provider = await buildSelectedProvider(
      _MemoryStore(
        const AssistantCredentialState(
          profiles: [incomplete],
          selectedId: 'bad',
        ),
      ),
    );
    expect(provider, isNull);
  });

  test('读档失败时一键切换退回管理页，不把异常抛给页面', () async {
    expect(await buildSelectedProvider(_UnreadableStore()), isNull);
  });

  test('系统安全存储不可用时按「没有配置过」处理，不抛异常', () async {
    // 测试环境没有平台通道，正是「读不出来」的情形：控制台和助手页都必须在
    // 这种情况下正常打开，而不是白屏或报错。
    TestWidgetsFlutterBinding.ensureInitialized();
    final state = await SecureAssistantCredentialsStore().load();
    expect(state.profiles, isEmpty);
    expect(state.selectedId, isNull);
  });
}
