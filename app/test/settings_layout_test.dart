import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/screens/settings_screen.dart';
import 'package:plan_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    for (final font in ['Ahem', 'NotoSansSC']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [390.0, 1200.0]) {
    for (final dark in [false, true]) {
      testWidgets('settings bottom edges align at $width, dark=$dark', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        Api.instance.network.reset();
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                home: const RepaintBoundary(
                  key: ValueKey('settings'),
                  child: SettingsScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -2500),
            );
            await tester.pumpAndSettle();
            Rect card(String label) => tester.getRect(
              find
                  .ancestor(of: find.text(label), matching: find.byType(Card))
                  .first,
            );
            final about = card('关于 DDL Killer');
            for (final label in ['邀请朋友', '退出登录']) {
              final adjacent = card(label);
              expect(about.left, adjacent.left);
              expect(about.right, adjacent.right);
            }
            await expectLater(
              find.byKey(const ValueKey('settings')),
              matchesGoldenFile(
                'goldens/settings-bottom-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
              ),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
          () => MockClient((req) async {
            final body = switch (req.url.path) {
              '/api/account/email' => {
                'bound': true,
                'enabled': true,
                'masked_email': 'fi***@example.com',
              },
              '/api/me' => {
                'username': 'fictional_user',
                'nickname': '测试账号',
                'avatar': '',
                'has_schedule': false,
              },
              '/api/stats' => {'lists': 0, 'todos': 0, 'done': 0, 'courses': 0},
              _ => [],
            };
            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
      });
    }
  }
}
