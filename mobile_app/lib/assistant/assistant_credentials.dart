import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'assistant_provider.dart';
import 'providers/direct_llm_assistant_provider.dart';
import 'providers/gateway_assistant_provider.dart';

/// 在线助手的两种上游。
///
/// 定义放在这里而不是设置表单里：档案的存储格式需要能表达「这是哪一种」，
/// 表单、控制台、页面三处必须共用同一个枚举，否则存进去的模式读出来会认不出。
enum OnlineAssistantMode { gateway, ownModel }

/// 生成档案 id。
///
/// 不引 uuid 包：时间戳已足够区分用户手动添加的几条配置，加计数器只是防同微秒
/// 连点。测试全部用显式 id 构造档案，不依赖这里的随机性。
int _idCounter = 0;
String newProfileId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
    '-${(_idCounter++).toRadixString(16)}';

/// 一份**命名的**在线助手配置，也就是用户说的「一个 API」。
///
/// 两类凭据的区别见 `docs/assistant-model-access.md`：团队网关的访问码由团队签发，
/// 自带模型的 API Key 属于用户自己，两者都**不允许**写进源码、APK 或构建参数。
@immutable
class AssistantProfile {
  const AssistantProfile({
    required this.id,
    required this.name,
    required this.mode,
    this.endpoint = '',
    this.accessToken = '',
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  /// 稳定标识。选择、编辑、删除都以它为准，而不是以名字或地址为准——
  /// 名字可以改、地址可以改，改完还应该是同一条配置。
  final String id;

  /// 列表里显示的名字，例如「DeepSeek」「团队网关」。
  final String name;

  final OnlineAssistantMode mode;

  /// 团队网关模式下的完整聊天地址，以 `/v1/assistant/chat` 结尾。
  final String endpoint;

  /// 团队签发的网关访问码。
  final String accessToken;

  /// 自带模型模式下的模型服务地址，只需要填到 `/v1`。
  final String baseUrl;

  /// 用户自己的模型 API Key。
  final String apiKey;

  /// 自带模型模式下的模型名，例如 `deepseek-chat`。
  final String model;

  /// 保存时如果用户没填名字，用这个兜底。
  String autoName() {
    if (mode == OnlineAssistantMode.gateway) return '团队网关';
    return model.isNotEmpty ? model : '我的模型';
  }

  AssistantProfile withName(String value) => AssistantProfile(
        id: id,
        name: value,
        mode: mode,
        endpoint: endpoint,
        accessToken: accessToken,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
      );

  String get modeLabel =>
      mode == OnlineAssistantMode.gateway ? '团队网关' : '我的模型';

  /// 控制台列表里的副标题：只说「发到哪」，不回显任何凭据。
  String get summary {
    if (mode == OnlineAssistantMode.gateway) {
      return endpoint.isNotEmpty ? endpoint : '（未填写服务地址）';
    }
    final parts = [
      if (model.isNotEmpty) model,
      if (baseUrl.isNotEmpty) baseUrl,
    ];
    return parts.isEmpty ? '（未填写模型服务）' : parts.join(' · ');
  }

  /// 给用户确认「存的是哪一个」用，只露最后 4 位。
  String get maskedSecret {
    final secret =
        mode == OnlineAssistantMode.gateway ? accessToken : apiKey;
    if (secret.isEmpty) return '未填写';
    if (secret.length <= 4) return '••••';
    return '••••••${secret.substring(secret.length - 4)}';
  }

  /// 按模式构造 provider。
  ///
  /// 校验失败（地址不对、Key 为空）会抛 `AssistantException`，由调用方转成提示；
  /// 这里只做构造，不发任何网络请求。
  AssistantProvider toProvider() => switch (mode) {
        OnlineAssistantMode.gateway => GatewayAssistantProvider(
            endpoint: endpoint,
            accessToken: accessToken,
          ),
        OnlineAssistantMode.ownModel => DirectLlmAssistantProvider(
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model,
          ),
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode.name,
        // 下划线风格只为了和网关契约看起来一致；这些字段名不出本机。
        'endpoint': endpoint,
        'access_token': accessToken,
        'base_url': baseUrl,
        'api_key': apiKey,
        'model': model,
      };

  /// 解析单条档案；任何无法识别的输入都返回 null。
  ///
  /// 安全存储里的内容可能来自旧版本，也可能被系统解密失败弄坏。这里返回 null
  /// 让调用方按「没有保存过」处理，好过在控制台里抛异常。
  static AssistantProfile? fromJson(Object? data) {
    if (data is! Map) return null;
    final mode = switch (data['mode']) {
      'gateway' => OnlineAssistantMode.gateway,
      'ownModel' => OnlineAssistantMode.ownModel,
      _ => null,
    };
    if (mode == null) return null;
    String text(Object? value) => value is String ? value : '';
    final id = text(data['id']);
    final name = text(data['name']);
    final derivedId =
        'legacy-${mode.name}-${text(data['endpoint'])}${text(data['base_url'])}';
    return AssistantProfile(
      // 老档没有 id：用内容派生一个稳定的替代值，保证它仍然可被选中和删除。
      id: id.isNotEmpty ? id : derivedId,
      // 旧档没有 name 就保持为空：兜底显示名由 autoName() 负责。在这里用 model
      // 填进去，会让「存下来的」和「用户填过的」变得分不清。
      name: name,
      mode: mode,
      endpoint: text(data['endpoint']),
      accessToken: text(data['access_token']),
      baseUrl: text(data['base_url']),
      apiKey: text(data['api_key']),
      model: text(data['model']),
    );
  }
}

/// 存下来的全部档案 + 当前选中的是哪一条。
///
/// 选中项和列表必须一起落盘：只存列表的话，下次打开就不知道用户上次用的是哪个，
/// 「点一下切在线」也就无从谈起。
@immutable
class AssistantCredentialState {
  const AssistantCredentialState({
    this.profiles = const [],
    this.selectedId,
  });

  final List<AssistantProfile> profiles;
  final String? selectedId;

  static const empty = AssistantCredentialState();

  /// 按 id 找一条档案；id 为 null 或找不到就返回 null。
  AssistantProfile? profileById(String? id) {
    if (id == null) return null;
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  AssistantProfile? get selectedProfile => profileById(selectedId);

  AssistantCredentialState withSelection(String? id) =>
      AssistantCredentialState(profiles: profiles, selectedId: id);

  Map<String, dynamic> toJson() => {
        'version': 2,
        'selected_id': selectedId,
        'profiles': [for (final profile in profiles) profile.toJson()],
      };

  /// 损坏、旧格式或空内容一律返回 [empty]，调用方不用区分这几种情况。
  static AssistantCredentialState fromJson(Object? data) {
    if (data is! Map) return empty;
    final raw = data['profiles'];
    if (raw is! List) return empty;
    final profiles = <AssistantProfile>[];
    for (final entry in raw) {
      final profile = AssistantProfile.fromJson(entry);
      // 单条坏掉不该让整份配置消失：跳过它，保留其余可用的。
      if (profile != null) profiles.add(profile);
    }
    final selectedId = data['selected_id'];
    return AssistantCredentialState(
      profiles: profiles,
      selectedId: selectedId is String ? selectedId : null,
    );
  }
}

/// 档案的读写接口。测试用内存实现替换。
abstract class AssistantCredentialsStore {
  Future<AssistantCredentialState> load();
  Future<void> save(AssistantCredentialState state);
  Future<void> clear();
}

/// 用系统安全存储（Android Keystore / iOS Keychain）加密保存。
///
/// 这是唯一允许的落盘方式：`shared_preferences` 是明文，绝不能用来存 Key。
/// 用户在控制台删除某条配置时，写回的内容里就不再包含它。
class SecureAssistantCredentialsStore implements AssistantCredentialsStore {
  /// 不传 `AndroidOptions`：默认实现已经用 Keystore 支持的密钥加密。
  /// 若团队要改用 Jetpack Security 的 `EncryptedSharedPreferences`，先在实际
  /// 插件版本上确认参数名再打开，别凭记忆写。
  SecureAssistantCredentialsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _stateKey = 'assistant_credentials_v2';

  /// 上一版只存一条凭据，键名不同。留着它只为一次性迁移。
  static const _legacyKey = 'assistant_credentials_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<AssistantCredentialState> load() async {
    try {
      final raw = await _storage.read(key: _stateKey);
      if (raw != null) return AssistantCredentialState.fromJson(jsonDecode(raw));
      return await _migrateLegacy();
    } catch (_) {
      // 读不出来（旧格式、解密失败）就当作没有配置过：控制台不该因此打不开。
      return AssistantCredentialState.empty;
    }
  }

  /// 把上一版的单条凭据包成一条档案。
  ///
  /// 只读时返回，不在这里写 v2——迁移的写入交给下一次 [save]，读操作就只读。
  /// id 沿用 `fromJson` 由内容派生的那个（而不是现生成一个）：同一个存档读两次
  /// 得到同一条档案，选中项才有意义。
  Future<AssistantCredentialState> _migrateLegacy() async {
    final raw = await _storage.read(key: _legacyKey);
    if (raw == null) return AssistantCredentialState.empty;
    var profile = AssistantProfile.fromJson(jsonDecode(raw));
    if (profile == null) return AssistantCredentialState.empty;
    if (profile.name.isEmpty) profile = profile.withName(profile.autoName());
    return AssistantCredentialState(
      profiles: [profile],
      selectedId: profile.id,
    );
  }

  @override
  Future<void> save(AssistantCredentialState state) async {
    await _storage.write(key: _stateKey, value: jsonEncode(state.toJson()));
    // v2 写成功后再清掉旧键，避免中途失败两头都读不到。
    await _storage.delete(key: _legacyKey);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _stateKey);
    await _storage.delete(key: _legacyKey);
  }
}

/// 读当前选中的档案，供页面「点一下切在线」和控制台关闭后的对齐使用。
///
/// 读档失败或没有选中项时返回 null。这里**不抛异常**也不回显任何凭据：
/// 这是切换路径，不是配置路径。
Future<AssistantProfile?> selectedProfile(
  AssistantCredentialsStore store,
) async {
  try {
    final state = await store.load();
    return state.selectedProfile;
  } catch (_) {
    return null;
  }
}

/// 读当前选中的档案并构造 provider，供页面「点一下切在线」使用。
///
/// 没有选中项、或构造失败（地址/Key 不完整）时返回 null，由调用方转去打开控制台。
/// 这里**不抛异常**也不回显任何凭据：这是切换路径，不是配置路径。
Future<AssistantProvider?> buildSelectedProvider(
  AssistantCredentialsStore store,
) async {
  final profile = await selectedProfile(store);
  if (profile == null) return null;
  try {
    return profile.toProvider();
  } catch (_) {
    // 地址不完整、Key 被清掉……都只是「这次没法一键切」，
    // 交给调用方打开管理页，不要在这里把异常抛给页面。
    return null;
  }
}
