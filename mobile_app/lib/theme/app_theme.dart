import 'package:flutter/material.dart';

/// 品牌种子色。全 App 的配色都从它派生。
const parcelLavender = Color(0xffe8daf3);
const parcelPeach = Color(0xffffe1c9);
const _seedColor = Color(0xffb69ccf);

/// App 主题。只在 `main.dart` 里装配，页面不要再写死颜色。
///
/// **只有这一套（浅色）。** 曾经有过「跟随系统 / 浅色 / 深色」三态切换与
/// 外观控制器，已按需求移除，所以这里不再收 [Brightness]、也不再需要
/// 持久化（旧存档键 `app.theme_mode` 可能会留在用户机器上，已不再读写）。
ThemeData buildAppTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: _seedColor,
        brightness: Brightness.light,
      ).copyWith(
        primary: const Color(0xff75518c),
        onPrimary: Colors.white,
        primaryContainer: parcelLavender,
        onPrimaryContainer: const Color(0xff39234a),
        secondary: const Color(0xff9b5832),
        onSecondary: Colors.white,
        secondaryContainer: parcelPeach,
        onSecondaryContainer: const Color(0xff4f2818),
        tertiary: const Color(0xff9b5832),
        onTertiary: Colors.white,
        tertiaryContainer: parcelPeach,
        onTertiaryContainer: const Color(0xff4f2818),
        surface: const Color(0xfffff9fd),
        surfaceContainerLow: const Color(0xfff6eff9),
        surfaceContainerHighest: const Color(0xffeee4f4),
        onSurface: const Color(0xff302837),
        onSurfaceVariant: const Color(0xff61566b),
      );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 背景与 AppBar 都取自 colorScheme，不写死 0xfff5f7f8 这类常量：
    // 写死的话换个配色方案背景就会与整页脱节。
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      centerTitle: false,
    ),
  );
}
