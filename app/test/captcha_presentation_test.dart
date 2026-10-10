import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/theme.dart';
import 'package:plan_app/widgets/email_captcha_dialog.dart';
import 'package:plan_app/widgets/captcha_image.dart';
import 'package:plan_app/screens/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    testWidgets('recovery captcha has smooth corners in dark=$dark', (
      tester,
    ) async {
      Api.instance.network.reset();
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => emailCaptchaDialog(context),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          final graphic = tester.getRect(find.byType(SvgPicture));
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          final cornerLuminance = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final index =
                ((graphic.top + 1).floor() * image.width +
                    (graphic.left + 1).floor()) *
                4;
            final color = Color.fromARGB(
              255,
              pixels.getUint8(index),
              pixels.getUint8(index + 1),
              pixels.getUint8(index + 2),
            );
            image.dispose();
            return color.computeLuminance();
          });
          if (dark) {
            expect(
              cornerLuminance,
              lessThan(.2),
              reason: 'The image corner must reveal the dark dialog, not its square SVG background.',
            );
          }
          await expectLater(
            find.byKey(const ValueKey('capture')),
            matchesGoldenFile(
              'goldens/captcha-dialog-${dark ? 'dark' : 'light'}.png',
            ),
          );
          expect(tester.takeException(), isNull);
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 'synthetic-captcha',
              'svg': File('test/fixtures/captcha.svg').readAsStringSync(),
            }),
            200,
          ),
        ),
      );
    });
  }

  testWidgets(
    'refresh is single flight, recovers from failure and submits the new challenge',
    (tester) async {
      Api.instance.network.reset();
      var requests = 0;
      final pending = Completer<http.Response>();
      ({String id, String code})? submitted;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      submitted = await emailCaptchaDialog(context);
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'old');
          await tester.tap(find.byType(CaptchaImage));
          await tester.pump();
          await tester.tap(find.byType(CaptchaImage));
          await tester.pump();
          expect(requests, 2);
          expect(
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '继续'))
                .onPressed,
            isNull,
          );
          pending.complete(
            http.Response(jsonEncode({'error': 'unavailable'}), 400),
          );
          await tester.pumpAndSettle();
          expect(find.text('验证码加载失败，请点击图片重试'), findsOneWidget);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'old',
          );
          expect(
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '继续'))
                .onPressed,
            isNull,
          );
          await tester.tap(find.byType(CaptchaImage));
          await tester.pumpAndSettle();
          expect(requests, 3);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            isEmpty,
          );
          await tester.enterText(find.byType(TextField), 'fresh');
          await tester.tap(find.text('继续'));
          await tester.pumpAndSettle();
          expect(submitted, (id: 'challenge-3', code: 'fresh'));
          expect(tester.takeException(), isNull);
        },
        () => MockClient((_) async {
          requests++;
          if (requests == 2) return pending.future;
          return http.Response(
            jsonEncode({
              'id': 'challenge-$requests',
              'svg': File('test/fixtures/captcha.svg').readAsStringSync(),
            }),
            200,
          );
        }),
      );
    },
  );

  for (final web in [false, true]) {
    testWidgets(
      'registration captcha fits a 320 phone in web=$web and clears old input on refresh',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        Api.instance.network.reset();
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var requests = 0;
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildDarkTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(1.3)),
                  child: child!,
                ),
                home: LoginScreen(debugWebLayout: web),
              ),
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('创建一个账号'));
            await tester.tap(find.text('创建一个账号'));
            await tester.pumpAndSettle();
            final input = find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == '验证码',
            );
            await tester.ensureVisible(input);
            await tester.enterText(input, 'old');
            await tester.ensureVisible(find.byType(CaptchaImage));
            final rect = tester.getRect(find.byType(CaptchaImage));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(320));
            await tester.tap(find.byType(CaptchaImage));
            await tester.pumpAndSettle();
            expect(requests, 2);
            expect(tester.widget<TextField>(input).controller!.text, isEmpty);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
          () => MockClient((req) async {
            if (req.url.path == '/api/auth/captcha') {
              requests++;
              return http.Response(
                jsonEncode({
                  'id': 'challenge-$requests',
                  'svg': File('test/fixtures/captcha.svg').readAsStringSync(),
                }),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        );
      },
    );
  }
}
