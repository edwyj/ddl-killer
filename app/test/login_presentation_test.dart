import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/screens/login_screen.dart';
import 'package:plan_app/widgets/login_presentation.dart';

void main() {
  testWidgets(
    'submit stays branded while busy and prevents repeated submission',
    (tester) async {
      var submissions = 0;
      var busy = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return LoginSubmitButton(
                  busy: busy,
                  label: '登录',
                  onPressed: () => submissions++,
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      expect(submissions, 1);
      final readyGradient =
          tester
                  .widget<DecoratedBox>(find.byType(DecoratedBox).first)
                  .decoration
              as BoxDecoration;
      expect(readyGradient.gradient, isA<LinearGradient>());
      update(() => busy = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('正在登录…'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      final busyGradient =
          tester
                  .widget<DecoratedBox>(find.byType(DecoratedBox).first)
                  .decoration
              as BoxDecoration;
      expect(busyGradient.gradient, readyGradient.gradient);
      update(() => busy = false);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      expect(submissions, 2);
      expect(tester.takeException(), isNull);
    },
  );
  setUpAll(() async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final emoji = FontLoader('NotoColorEmoji')
      ..addFont(rootBundle.load('assets/fonts/NotoColorEmoji.ttf'));
    await emoji.load();
  });
  for (final config in [
    (name: 'desktop', size: const Size(1440, 900), dark: false),
    (name: 'mobile', size: const Size(390, 760), dark: false),
    (name: 'dark', size: const Size(390, 760), dark: true),
    (name: 'short', size: const Size(390, 400), dark: false),
  ]) {
    testWidgets('web presentation ${config.name}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = config.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansSC',
            fontFamilyFallback: const ['NotoColorEmoji'],
            brightness: config.dark ? Brightness.dark : Brightness.light,
          ),
          home: const RepaintBoundary(
            key: ValueKey('page'),
            child: LoginScreen(debugWebLayout: true),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/icon/app_icon.png'),
          tester.element(find.byType(LoginScreen)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('欢迎回来'), findsOneWidget);
      expect(find.text('继续安排今天。'), findsOneWidget);
      expect(find.text('清单、DDL、课表与日程，一处管理'), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);
      final rect = tester.getRect(find.byType(TextField).first);
      expect(rect.width, lessThanOrEqualTo(444));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(config.size.width));
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      if (config.name == 'desktop') {
        expect(scrollable.position.maxScrollExtent, 0);
      }
      if (config.name == 'short') {
        expect(scrollable.position.maxScrollExtent, greaterThan(0));
        await tester.ensureVisible(find.text('登录'));
      }
      expect(tester.takeException(), isNull);
      if (config.name != 'short') {
        await expectLater(
          find.byKey(const ValueKey('page')),
          matchesGoldenFile('goldens/login-${config.name}.png'),
        );
      }
    });
  }
  testWidgets(
    'small native layout retains input, offline choice and keyboard access',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const LoginScreen(debugWebLayout: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载 Android 版'), findsNothing);
      final checkbox = find.byType(CheckboxListTile);
      await tester.ensureVisible(checkbox);
      final previous = tester.widget<CheckboxListTile>(checkbox).value;
      await tester.tap(checkbox);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(checkbox).value, !previous!);
      await tester.enterText(
        find.byType(TextField).first,
        'local-layout-check',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('登录'));
      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      expect(find.text('请输入账号和密码'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'local-layout-check',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
