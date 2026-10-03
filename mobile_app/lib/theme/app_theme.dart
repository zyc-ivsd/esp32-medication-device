import 'package:flutter/material.dart';

/// 品牌种子色。全 App 的配色都从它派生。
const _seedColor = Color(0xff147d79);

/// App 主题。只在 `main.dart` 里装配，页面不要再写死颜色。
///
/// **只有这一套（浅色）。** 曾经有过「跟随系统 / 浅色 / 深色」三态切换与
/// 外观控制器，已按需求移除，所以这里不再收 [Brightness]、也不再需要
/// 持久化（旧存档键 `app.theme_mode` 可能会留在用户机器上，已不再读写）。
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.light,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 背景与 AppBar 都取自 colorScheme，不写死 0xfff5f7f8 这类常量：
    // 写死的话换个配色方案背景就会与整页脱节。
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      centerTitle: false,
    ),
  );
}
