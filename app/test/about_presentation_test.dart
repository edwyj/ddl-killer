import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/app_updates.dart';
import 'package:plan_app/app_version.dart';
import 'package:plan_app/screens/about_screen.dart';
import 'package:plan_app/theme.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final dark in [false, true]) {
    testWidgets('about latest release compact mobile dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final updates = AppUpdates(
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'version': AppVersion.name,
                'build_number': AppVersion.build,
                'notes': AppVersion.notes,
                'apk_url':
                    'https://ddlkiller.com/releases/ddl-killer-${AppVersion.name}-${AppVersion.build}.apk',
              }),
            ),
            200,
          ),
        ),
      );
      await updates.check();
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          home: RepaintBoundary(
            key: const ValueKey('about-page'),
            child: AboutScreen(updates: updates),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/icon/app_icon.png'),
          tester.element(find.byType(AboutScreen)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最新版本变化'), findsOneWidget);
      expect(find.text('已经是最新版本'), findsOneWidget);
      expect(find.textContaining('0.9.3：'), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('about-page')),
        matchesGoldenFile('goldens/about-${dark ? 'dark' : 'light'}.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      updates.dispose();
    });
  }
}
