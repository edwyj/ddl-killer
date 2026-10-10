import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/appearance_screen.dart';
import 'package:plan_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.mode.value = ThemeMode.light;
    ThemeController.palette.value = AppColorTheme.teal;
  });

  testWidgets('mode and palette update immediately and persist', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildLightTheme(), home: const AppearanceScreen()),
    );
    await tester.tap(find.text('深色'));
    await tester.tap(find.text('薰衣草'));
    await tester.pump();
    expect(ThemeController.mode.value, ThemeMode.dark);
    expect(ThemeController.palette.value, AppColorTheme.lilac);
    final storage = await SharedPreferences.getInstance();
    expect(storage.getString('theme_mode'), 'dark');
    expect(storage.getString('theme_palette_v1'), 'lilac');
  });

  test('load restores palette and invalid value falls back safely', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'system',
      'theme_palette_v1': 'orange',
    });
    await ThemeController.load();
    expect(ThemeController.mode.value, ThemeMode.system);
    expect(ThemeController.palette.value, AppColorTheme.orange);
  });
}
