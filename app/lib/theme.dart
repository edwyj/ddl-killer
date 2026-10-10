import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appearance_platform.dart' as appearance;

/// 全局主题：TickTick 湖蓝浅色为主，可切深色 / 跟随系统，选择会持久化。
class ThemeController {
  static const _kTheme = 'theme_mode';
  static const _kPalette = 'theme_palette_v1';

  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  static bool _watching = false;
  static final ValueNotifier<AppColorTheme> palette = ValueNotifier(
    AppColorTheme.teal,
  );

  /// 优先读取本机选择；网页与官网共享外观，无记录时跟随系统。
  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final v = appearance.read() ?? sp.getString(_kTheme);
    palette.value = AppColorTheme.values.firstWhere(
      (item) => item.name == sp.getString(_kPalette),
      orElse: () => AppColorTheme.teal,
    );
    switch (v) {
      case 'dark':
        mode.value = ThemeMode.dark;
      case 'light':
        mode.value = ThemeMode.light;
      case 'system':
        mode.value = ThemeMode.system;
      default:
        mode.value = ThemeMode.system;
    }
    appearance.write(mode.value.name);
    if (!_watching) {
      _watching = true;
      appearance.watch((value) {
        final next = ThemeMode.values.firstWhere(
          (item) => item.name == value,
          orElse: () => ThemeMode.system,
        );
        if (next != mode.value) set(next);
      });
    }
  }

  /// 设置主题并持久化。
  static Future<void> set(ThemeMode m) async {
    mode.value = m;
    appearance.write(m.name);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTheme, switch (m) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    });
  }

  static Future<void> setPalette(AppColorTheme value) async {
    palette.value = value;
    await (await SharedPreferences.getInstance()).setString(
      _kPalette,
      value.name,
    );
  }
}

enum AppColorTheme {
  teal('湖蓝', Color(0xFF57B0A6)),
  mint('薄荷', Color(0xFF52A675)),
  tomato('番茄红', Color(0xFFC94B3C)),
  orange('暖橙', Color(0xFFE07A35)),
  lilac('薰衣草', Color(0xFF8067C7)),
  navy('海军蓝', Color(0xFF4669A8)),
  graphite('石墨', Color(0xFF626973));

  const AppColorTheme(this.label, this.seed);
  final String label;
  final Color seed;
}

// 主色(海青绿 teal，对照参考图 TickTick 的 accent，约 #57B0A6)
const seed = Color(0xFF57B0A6);

/// 近黑正文/标题色(浅色模式)
const ink = Color(0xFF22252B);

ThemeData buildLightTheme([AppColorTheme palette = AppColorTheme.teal]) {
  final scheme = ColorScheme.fromSeed(seedColor: palette.seed);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const ['NotoColorEmoji'],
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF7F8FA),
    textTheme: const TextTheme(
      // 更重的标题，接近 TickTick 的加粗近黑
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: ink,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFFF7F8FA),
      foregroundColor: ink,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: const TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    dividerColor: const Color(0xFFE5E7EB),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.seed,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

ThemeData buildDarkTheme([AppColorTheme palette = AppColorTheme.teal]) {
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.seed,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const ['NotoColorEmoji'],
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF16161A),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      bodyMedium: TextStyle(fontSize: 14),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF16161A),
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF1F1F24),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    dividerColor: const Color(0xFF2A2A31),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.seed,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
