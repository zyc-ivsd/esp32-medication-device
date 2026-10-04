import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/assistant/assistant_credentials.dart';
import 'package:medication_device_app/assistant/assistant_settings_dialog.dart';

/// 表单是弹出去的，结果在 pop 之后才拿得到，所以用一个可变的小盒子接住。
class _FormHarness {
  AssistantProfile? result;
  bool closed = false;
}

/// 对话框内容比默认视口高，放大视口免得控件落在可视区外点不到。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<_FormHarness> _openForm(
  WidgetTester tester, {
  AssistantProfile? initial,
}) async {
  _useTallViewport(tester);
  final harness = _FormHarness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                harness.result = await showDialog<AssistantProfile>(
                  context: context,
                  builder: (_) => AssistantSettingsDialog(initial: initial),
                );
                harness.closed = true;
              },
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开表单'));
  await tester.pumpAndSettle();
  return harness;
}

String? fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller?.text;

Future<void> agreeAndSave(WidgetTester tester) async {
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

const _presets = <String, String>{
  'DeepSeek': 'https://api.deepseek.com/v1',
  'Qwen': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  'Kimi': 'https://api.moonshot.cn/v1',
  'GLM': 'https://open.bigmodel.cn/api/paas/v4',
};

void main() {
  testWidgets('点预设一下填好地址与模型名，名字空着才补', (tester) async {
    await _openForm(tester);
    expect(find.text('Service presets'), findsOneWidget);

    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'model-base-url'), 'https://api.deepseek.com/v1');
    expect(fieldText(tester, 'model-name'), 'deepseek-chat');
    expect(fieldText(tester, 'profile-name'), 'DeepSeek');

    // 用户自己起过名字就不该被预设覆盖。
    await tester.enterText(find.byKey(const Key('profile-name')), '我的首选');
    await tester.tap(find.text('Qwen'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'profile-name'), '我的首选');
    expect(
      fieldText(tester, 'model-base-url'),
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
    expect(fieldText(tester, 'model-name'), 'qwen-plus');
  });

  testWidgets('每个预设地址都能通过保存前的校验', (tester) async {
    for (final entry in _presets.entries) {
      final harness = await _openForm(tester);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      // 只补一个 Key：地址本身有问题的话，保存会被拦下。
      await tester.enterText(find.byKey(const Key('model-api-key')), 'k');
      await agreeAndSave(tester);
      expect(harness.closed, isTrue, reason: entry.key);
      expect(harness.result?.baseUrl, entry.value, reason: entry.key);
    }
  });

  testWidgets('自带模型的输入框带填写示范', (tester) async {
    await _openForm(tester);
    // 只填到 /v1 也可以，路径由 App 补齐——这点必须写在界面上。
    expect(find.textContaining('base URL ending in /v1'), findsOneWidget);
    expect(find.text('https://api.deepseek.com/v1'), findsOneWidget);
    expect(find.text('deepseek-chat'), findsOneWidget);
  });

  testWidgets('姓名留空时用兜底名，保存后回到调用方', (tester) async {
    final harness = await _openForm(tester);
    await tester.enterText(
      find.byKey(const Key('model-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(find.byKey(const Key('model-api-key')), 'k');
    await tester.enterText(find.byKey(const Key('model-name')), 'my-model');
    await agreeAndSave(tester);

    expect(harness.result?.name, 'my-model');
    expect(harness.result?.id, isNotEmpty);
  });

  testWidgets('同意是保存的前提，未同意时保存不可点', (tester) async {
    await _openForm(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('地址不完整或 Key 为空时就地报错，不返回配置', (tester) async {
    final harness = await _openForm(tester);
    await tester.enterText(
      find.byKey(const Key('model-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(find.byKey(const Key('model-name')), 'm');
    await agreeAndSave(tester);
    expect(find.textContaining('API key'), findsWidgets);
    expect(harness.result, isNull);
  });

  testWidgets('编辑已有配置时全部字段预填', (tester) async {
    const existing = AssistantProfile(
      id: 'm1',
      name: 'DeepSeek',
      mode: OnlineAssistantMode.ownModel,
      baseUrl: 'https://api.deepseek.com/v1',
      apiKey: 'saved-key',
      model: 'deepseek-chat',
    );
    await _openForm(tester, initial: existing);

    expect(find.text('Edit API'), findsOneWidget);
    expect(fieldText(tester, 'profile-name'), 'DeepSeek');
    expect(fieldText(tester, 'model-base-url'), 'https://api.deepseek.com/v1');
    expect(fieldText(tester, 'model-api-key'), 'saved-key');
    expect(fieldText(tester, 'model-name'), 'deepseek-chat');
  });

  testWidgets('凭据默认打码，点「显示」才看得见', (tester) async {
    await _openForm(
      tester,
      initial: const AssistantProfile(
        id: 'm1',
        name: 'DeepSeek',
        mode: OnlineAssistantMode.ownModel,
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'saved-key',
        model: 'deepseek-chat',
      ),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model-api-key')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('model-api-key')))
          .obscureText,
      isFalse,
    );
  });

  testWidgets('保存前写明发送什么、不发送什么、凭据存在哪', (tester) async {
    await _openForm(tester);

    expect(find.textContaining('Your current question'), findsOneWidget);
    expect(find.text('Excluded from the record summary'), findsOneWidget);
    expect(
      find.textContaining('Raw records and individual timestamps'),
      findsOneWidget,
    );
    expect(find.text('Credential storage'), findsOneWidget);
    expect(
      find.textContaining('Save stores your configuration'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Delete it at any time in Manage APIs'),
      findsOneWidget,
    );
    expect(find.textContaining('never to a team server'), findsOneWidget);
    expect(find.textContaining('摘要经团队网关转发给模型'), findsNothing);
  });
}
