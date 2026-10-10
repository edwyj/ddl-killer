import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/theme.dart';
import 'package:plan_app/widgets/login_presentation.dart';
import 'package:plan_app/widgets/login_appearance_switch.dart';
import 'package:flutter/services.dart';

void main() {
  tearDown(() => ThemeController.mode.value = ThemeMode.system);

  for (final dark in [false, true]) {
    testWidgets(
      'native appearance menu stays inside a narrow screen dark=$dark',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await ThemeController.set(dark ? ThemeMode.dark : ThemeMode.light);
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: LoginPresentation(
              registering: false,
              form: (_) => const Text('输入区域'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('外观模式'));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(3));
        expect(find.byIcon(Icons.check), findsOneWidget);
        for (final item in find.byType(MenuItemButton).evaluate()) {
          final rect = tester.getRect(find.byWidget(item.widget));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
          expect(rect.bottom, lessThanOrEqualTo(640));
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        await tester.tap(find.byTooltip('外观模式'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('输入区域'));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.byType(LoginAppearanceSwitch), findsOneWidget);
        await tester.tap(find.byTooltip('外观模式'));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.byType(LoginAppearanceSwitch), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('missing and invalid appearance return to system; saved choice survives load', () async {
    SharedPreferences.setMockInitialValues({});
    ThemeController.mode.value = ThemeMode.dark;
    await ThemeController.load();
    expect(ThemeController.mode.value, ThemeMode.system);
    await ThemeController.set(ThemeMode.dark);
    ThemeController.mode.value = ThemeMode.light;
    await ThemeController.load();
    expect(ThemeController.mode.value, ThemeMode.dark);
    await (await SharedPreferences.getInstance()).setString(
      'theme_mode',
      'invalid',
    );
    await ThemeController.load();
    expect(ThemeController.mode.value, ThemeMode.system);
  });

  testWidgets(
    'login switch changes theme, persists and follows system brightness',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await ThemeController.load();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.mode,
          builder: (context, mode, _) => MaterialApp(
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: mode,
            home: LoginPresentation(
              registering: false,
              form: (context) => const Text('输入区域'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Brightness brightness() =>
          Theme.of(tester.element(find.text('输入区域'))).brightness;
      expect(brightness(), Brightness.dark);
      await tester.tap(find.byTooltip('外观模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浅色').last);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'light',
      );
      await tester.tap(find.byTooltip('外观模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随系统').last);
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
      expect(tester.takeException(), isNull);
    },
  );
}
