import 'dart:async';

import 'package:flutter/material.dart';

import 'assistant_credentials.dart';
import 'assistant_exception.dart';
import 'assistant_provider.dart';
import 'assistant_service.dart';
import 'assistant_settings_dialog.dart';

/// 「管理 API」控制台：查看、选择、修改、删除已保存的在线助手配置。
///
/// 这里是**唯一**会写安全存储的地方（新增、编辑、删除、切换选中都经它落盘），
/// 表单只管收集字段。这样「界面上看到的」和「存下来的」不会各说各话。
///
/// 打开方式：`showDialog<AssistantService>`。用户点了「使用」才带着新的
/// [AssistantService] 关掉；直接关闭返回 null，调用方据此保持原状。
class AssistantApiConsole extends StatefulWidget {
  const AssistantApiConsole({super.key, this.store});

  /// 测试注入用；默认走系统安全存储。
  final AssistantCredentialsStore? store;

  @override
  State<AssistantApiConsole> createState() => _AssistantApiConsoleState();
}

class _AssistantApiConsoleState extends State<AssistantApiConsole> {
  late final AssistantCredentialsStore _store;
  AssistantCredentialState _state = AssistantCredentialState.empty;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? SecureAssistantCredentialsStore();
    unawaited(_load());
  }

  Future<void> _load() async {
    AssistantCredentialState state;
    try {
      state = await _store.load();
    } catch (_) {
      state = AssistantCredentialState.empty;
      if (mounted) {
        setState(
          () => _error =
              'Saved APIs could not be loaded. Check your system settings and try again.',
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
    });
  }

  /// 写入成功后本地状态才跟着变。
  ///
  /// 写失败却先改了界面，用户会以为改动已经保存——下次打开发现没了，
  /// 而删除失败更糟：会以为 Key 已经清掉了。
  Future<bool> _persist(AssistantCredentialState next) async {
    try {
      await _store.save(next);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Secure storage could not be updated. Your changes were not saved.',
        );
      }
      return false;
    }
    if (!mounted) return false;
    setState(() {
      _state = next;
      _error = null;
    });
    return true;
  }

  /// 构造这条档案的 provider；走不通时把原因写进 [_error] 并返回 null。
  ///
  /// 返回值保持可空，是为了让调用方必须显式处理「这条路走不通」，
  /// 而不是把构造异常抛给页面。
  AssistantProvider? _resolveProvider(AssistantProfile profile) {
    try {
      return profile.toProvider();
    } on AssistantException catch (error) {
      setState(() => _error = error.message);
      return null;
    } catch (_) {
      setState(
        () => _error =
            'This configuration is incomplete. Edit it to fill in the missing fields.',
      );
      return null;
    }
  }

  /// 选中某条并切到在线。
  Future<void> _use(AssistantProfile profile) async {
    final provider = _resolveProvider(profile);
    if (provider == null) return;
    if (!await _persist(_state.withSelection(profile.id))) return;
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(AssistantService(provider: provider, isRemote: true));
  }

  /// 打开表单。`existing` 为 null 表示新增。
  Future<void> _edit(AssistantProfile? existing) async {
    final saved = await showDialog<AssistantProfile>(
      context: context,
      builder: (_) => AssistantSettingsDialog(initial: existing),
    );
    if (saved == null || !mounted) return;

    final profiles = [..._state.profiles];
    final index = profiles.indexWhere((item) => item.id == saved.id);
    final isNew = index < 0;
    if (isNew) {
      profiles.add(saved);
    } else {
      profiles[index] = saved;
    }
    // 新增的这条直接设为选中（用户刚加完，就是要用它）。改一条已有配置则不动
    // 选中项——只改地址就被换掉默认 API，是个会让人意外的副作用。
    await _persist(
      AssistantCredentialState(
        profiles: profiles,
        selectedId: isNew ? saved.id : _state.selectedId,
      ),
    );
  }

  Future<void> _delete(AssistantProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this API?'),
        content: Text(
          '${profile.name} and its credentials will be removed from this phone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            // 和列表行上的「删除」区分开，避免二次确认里两个同名按钮。
            child: const Text('Delete API'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final profiles = [
      for (final item in _state.profiles)
        if (item.id != profile.id) item,
    ];
    // 删掉的正好是当前选中的那条时，选中项要一起清空：留着指向已删除档案的 id，
    // 一键切换会一直失败，用户还不知道为什么。
    final selectedId = _state.selectedId == profile.id
        ? null
        : _state.selectedId;
    await _persist(
      AssistantCredentialState(profiles: profiles, selectedId: selectedId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Manage APIs'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_state.profiles.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'No APIs saved yet. Add one to switch between Local and Online.',
                        ),
                      ),
                    for (final profile in _state.profiles)
                      _buildProfileCard(theme, profile),
                    const SizedBox(height: 4),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Text(
                      'Credentials are encrypted in Android secure storage. '
                      'You can delete them here at any time.',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _loading ? null : () => _edit(null),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add new API'),
        ),
      ],
    );
  }

  Widget _buildProfileCard(ThemeData theme, AssistantProfile profile) {
    final selected = profile.id == _state.selectedId;
    final isGateway = profile.mode == OnlineAssistantMode.gateway;
    final secretLabel = isGateway ? 'Access code' : 'API Key';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? theme.colorScheme.secondaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isGateway ? Icons.cloud_outlined : Icons.key_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    profile.name,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected) ...[
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text('Selected', style: theme.textTheme.labelSmall),
                ],
              ],
            ),
            const SizedBox(height: 4),
            // 只显示「发到哪」和掩码后的凭据，列表里不出现完整 Key。
            Text(
              '${profile.modeLabel} · $secretLabel ${profile.maskedSecret}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              profile.summary,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => _use(profile),
                  icon: const Icon(Icons.play_arrow_outlined, size: 18),
                  label: const Text('Use'),
                ),
                TextButton.icon(
                  onPressed: () => _edit(profile),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _delete(profile),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
