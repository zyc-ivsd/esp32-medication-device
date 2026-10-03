import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medication_device_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('App 只有一套浅色主题，且开着 Material 3', () {
    // 外观切换（跟随系统 / 浅色 / 深色）已按需求移除，主题不再分两套。
    final theme = buildAppTheme();
    expect(theme.brightness, Brightness.light);
    expect(theme.useMaterial3, isTrue);
  });

  test('背景与 AppBar 取自 colorScheme，不写死浅色常量', () {
    // 写死 0xfff5f7f8 这类常量后，一换配色方案背景就与整页脱节。
    final theme = buildAppTheme();
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
    expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
  });
}
