import 'package:flutter/material.dart';

import 'assistant_credentials.dart';
import 'assistant_exception.dart';

/// 一条在线助手配置的**编辑表单**（新增或修改）。
///
/// 它只管收集字段并返回 [AssistantProfile]，不碰安全存储——落盘由
/// `AssistantApiConsole` 统一负责。保存前会用 `toProvider()` 试构造一次，
/// 地址或 Key 不完整就地报错，不让一条用不了的配置存进列表。
///
/// 表单同时承担两件事，缺一不可：
/// 1. **便捷**：常见服务点一下自动填好地址与模型名，不用去翻文档；
/// 2. **透明**：保存前明确列出会发送什么、不发送什么、凭据存在哪。
class AssistantSettingsDialog extends StatefulWidget {
  const AssistantSettingsDialog({super.key, this.initial});

  /// 要修改的配置；为 null 表示新增。
  final AssistantProfile? initial;

  @override
  State<AssistantSettingsDialog> createState() =>
      _AssistantSettingsDialogState();
}

/// 常见 OpenAI 兼容服务，只用于「点一下填好示例」。
///
/// 这不是推荐列表，也不代表我们验证过这些服务：任何 OpenAI 兼容地址都可以手填。
/// 名字只在用户没填时补上。
class _ModelPreset {
  const _ModelPreset(this.label, this.baseUrl, this.model);

  final String label;
  final String baseUrl;
  final String model;
}

const _presets = [
  _ModelPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  _ModelPreset(
    'Qwen',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus',
  ),
  _ModelPreset('Kimi', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
  _ModelPreset('GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash'),
];

class _AssistantSettingsDialogState extends State<AssistantSettingsDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  String? _error;
  bool _consented = false;

  /// 凭据默认打码；「显示」只是让用户确认自己填的是哪一个，不做任何持久化。
  bool _showSecret = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _baseUrl = TextEditingController(text: initial?.baseUrl ?? '');
    _apiKey = TextEditingController(text: initial?.apiKey ?? '');
    _model = TextEditingController(text: initial?.model ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  /// 点一下预设：填地址和模型名，名字空着才补。
  void _applyPreset(_ModelPreset preset) {
    setState(() {
      _baseUrl.text = preset.baseUrl;
      _model.text = preset.model;
      if (_name.text.trim().isEmpty) _name.text = preset.label;
      _error = null;
    });
  }

  void _save() {
    var profile = AssistantProfile(
      id: widget.initial?.id ?? newProfileId(),
      name: _name.text.trim(),
      mode: OnlineAssistantMode.ownModel,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    );
    if (profile.name.isEmpty) profile = profile.withName(profile.autoName());
    try {
      // 试构造一次：地址/Key 不完整当场说清楚，别存下一条用不了的配置。
      profile.toProvider();
    } on AssistantException catch (error) {
      setState(() => _error = error.message);
      return;
    } catch (_) {
      setState(
        () => _error =
            'This configuration is incomplete. Check the fields and try again.',
      );
      return;
    }
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add API' : 'Edit API'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                key: const Key('profile-name'),
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'For example: DeepSeek',
                ),
              ),
              const SizedBox(height: 12),
              ..._buildOwnModelFields(theme),
              const SizedBox(height: 4),
              _buildPrivacyNotice(theme),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _consented,
                onChanged: (value) =>
                    setState(() => _consented = value ?? false),
                title: const Text(
                  'Allow each question and the current record summary to be sent',
                ),
                subtitle: const Text(
                  'Raw records and device identifiers are excluded. Session history is optional.',
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _consented ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildSecretField({
    required TextEditingController controller,
    required Key key,
    required String label,
  }) => TextField(
    controller: controller,
    key: key,
    obscureText: !_showSecret,
    enableSuggestions: false,
    autocorrect: false,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        onPressed: () => setState(() => _showSecret = !_showSecret),
        icon: Icon(
          _showSecret
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
        ),
        tooltip: _showSecret ? 'Hide' : 'Show',
      ),
    ),
  );

  List<Widget> _buildOwnModelFields(ThemeData theme) => [
    Text(
      'Use your own model service. Your API key is used on this phone and is never sent to a team server or written to logs.',
      style: theme.textTheme.bodyMedium,
    ),
    const SizedBox(height: 10),
    Text('Service presets', style: theme.textTheme.labelMedium),
    const SizedBox(height: 6),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final preset in _presets)
          ActionChip(
            label: Text(preset.label),
            onPressed: () => _applyPreset(preset),
          ),
      ],
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _baseUrl,
      key: const Key('model-base-url'),
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Model service URL',
        helperText:
            'Enter the base URL ending in /v1. The app adds /chat/completions.',
        hintText: 'https://api.deepseek.com/v1',
        helperMaxLines: 2,
      ),
    ),
    _buildSecretField(
      controller: _apiKey,
      key: const Key('model-api-key'),
      label: 'Your API key',
    ),
    TextField(
      controller: _model,
      key: const Key('model-name'),
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Model name',
        helperText: 'Use the name provided by your service',
        hintText: 'deepseek-chat',
        helperMaxLines: 2,
      ),
    ),
  ];

  /// 保存前必须看到的说明：发什么、不发什么、凭据在哪。
  Widget _buildPrivacyNotice(ThemeData theme) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sent with each question', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        const Text(
          '· Your current question, including any personal information you enter\n'
          '· Record summary: daily and weekly uses, daily counts, invalid uses, '
          'unknown and future times, and the last completed sync',
        ),
        const SizedBox(height: 10),
        Text(
          'Excluded from the record summary',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        const Text(
          '· Raw records and individual timestamps · Device or Bluetooth identifiers · Credentials. Session history is optional.',
        ),
        const SizedBox(height: 10),
        Text('Credential storage', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        const Text(
          '· Save stores your configuration in encrypted Android secure storage. '
          'Delete it at any time in Manage APIs.\n'
          '· Your key is sent directly to your selected model service, never to a team server or logs.',
        ),
      ],
    ),
  );
}
