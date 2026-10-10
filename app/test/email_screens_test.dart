import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/screens/login_screen.dart';
import 'package:plan_app/screens/ddl_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/email_account_screen.dart';
import 'package:plan_app/screens/forgot_password_screen.dart';
import 'package:plan_app/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'privacy_consent_flow.dart';

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
void main() {
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets(
      'reset password guidance is complete on a narrow phone at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: EmailAccountScreen(
              reset: true,
              actions: EmailAccountActions(
                status: () async => {'bound': false, 'enabled': true},
                request: (e, p, i, c) async => {},
                confirm: (r, b) async => null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(field('新密码'));
        await tester.tap(field('新密码'));
        await tester.pumpAndSettle();
        final guidance = find.text('至少12个字符，建议组合使用英文字母、数字和符号');
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: guidance, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'binding explains mailbox uniqueness and keeps a verified conflict recoverable',
    (tester) async {
      final actions = EmailAccountActions(
        status: () async => {'bound': false, 'enabled': true},
        request: (e, p, i, c) async => {
          'request_id': 'proof',
          'resend_after': 60,
          'message': '验证码请求已提交，收到后请填写验证码继续验证。',
        },
        confirm: (r, b) async => throw ApiException('这个邮箱已经绑定了其他账号，请换一个邮箱'),
      );
      await tester.pumpWidget(
        MaterialApp(home: EmailAccountScreen(actions: actions)),
      );
      await tester.pumpAndSettle();
      expect(find.text('一个邮箱只能绑定一个账号。'), findsOneWidget);
      await tester.enterText(field('当前密码'), 'Fictional-password-123');
      await tester.enterText(field('邮箱地址'), 'occupied@example.com');
      await tester.tap(find.text('获取验证码'));
      await tester.pumpAndSettle();
      expect(find.text('验证码请求已提交，收到后请填写验证码继续验证。'), findsOneWidget);
      await tester.enterText(field('邮箱验证码'), '123456');
      await tester.ensureVisible(find.text('确认绑定邮箱'));
      await tester.tap(find.text('确认绑定邮箱'));
      await tester.pumpAndSettle();
      expect(find.text('这个邮箱已经绑定了其他账号，请换一个邮箱'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('邮箱地址')).controller!.text,
        'occupied@example.com',
      );
      await tester.enterText(field('邮箱地址'), 'next@example.com');
      await tester.pump();
      expect(tester.widget<TextField>(field('邮箱验证码')).controller!.text, '');
      await tester.ensureVisible(find.textContaining('没有收到，请重试或联系开发者。'));
      await tester.pump();
      expect(find.textContaining('垃圾邮件'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  setUpAll(() async {
    await (FontLoader(
      'Ahem',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'NotoColorEmoji',
    )..addFont(rootBundle.load('assets/fonts/NotoColorEmoji.ttf'))).load();
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'live email change preserves explicit send failure, then verifies both mailboxes',
    (tester) async {
      var sends = 0, confirmations = 0;
      Api.instance.network.reset();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EmailAccountScreen(),
                      ),
                    ),
                    child: const Text('打开邮箱'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开邮箱'));
          await tester.pumpAndSettle();
          await tester.enterText(field('当前密码'), 'Fictional-password-123');
          await tester.enterText(field('邮箱地址'), 'new@example.com');
          await tester.tap(find.text('获取验证码'));
          await tester.pumpAndSettle();
          expect(find.text('测试版请联系开发者添加测试邮箱'), findsOneWidget);
          expect(
            tester.widget<TextField>(field('邮箱地址')).controller!.text,
            'new@example.com',
          );
          expect(
            tester.widget<TextField>(field('当前密码')).controller!.text,
            'Fictional-password-123',
          );
          expect(find.textContaining('未能确认保存结果'), findsNothing);
          await tester.ensureVisible(find.text('获取验证码'));
          await tester.tap(find.text('获取验证码'));
          await tester.pumpAndSettle();
          await tester.enterText(field('新邮箱验证码'), '123456');
          await tester.enterText(field('原邮箱验证码'), '654321');
          await tester.ensureVisible(find.text('确认更换邮箱'));
          await tester.tap(find.text('确认更换邮箱'));
          await tester.pumpAndSettle();
          expect(confirmations, 1);
          expect(find.text('打开邮箱'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          dynamic response;
          var status = 200;
          if (req.url.path == '/api/account/email' && req.method == 'GET') {
            response = {
              'bound': true,
              'enabled': true,
              'masked_email': 'ol***@example.com',
            };
          } else if (req.url.path == '/api/account/email/code') {
            sends++;
            if (sends == 1) {
              response = {'error': '测试版请联系开发者添加测试邮箱'};
              status = 503;
            } else {
              response = {
                'request_id': 'new-proof',
                'old_request_id': 'old-proof',
                'resend_after': 60,
                'message': '请查收原邮箱和新邮箱的验证码。',
              };
            }
          } else if (req.url.path == '/api/account/email' &&
              req.method == 'POST') {
            confirmations++;
            expect(jsonDecode(req.body), {
              'email': 'new@example.com',
              'password': 'Fictional-password-123',
              'request_id': 'new-proof',
              'code': '123456',
              'old_request_id': 'old-proof',
              'old_code': '654321',
            });
            response = {'ok': true};
          } else {
            throw StateError('Unexpected request');
          }
          return http.Response(
            jsonEncode(response),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );
  testWidgets('my page groups tools and account entries by purpose', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    for (final title in ['账号与安全', '计划与工具', '外观与数据', '消息与反馈', '邀请与奖励']) {
      await tester.scrollUntilVisible(
        find.text(title),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }
  });
  for (final dark in [false, true]) {
    testWidgets('email change stays centered on desktop in $dark mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = EmailAccountActions(
        status: () async => {
          'bound': true,
          'enabled': true,
          'masked_email': 'pe***@example.com',
        },
        request: (e, p, i, c) async => {},
        confirm: (r, b) async => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          home: RepaintBoundary(
            key: const ValueKey('desktop-email'),
            child: EmailAccountScreen(actions: actions),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(field('邮箱地址')).width, lessThanOrEqualTo(480));
      expect(tester.getCenter(field('邮箱地址')).dx, closeTo(640, 1));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('desktop-email')),
        matchesGoldenFile(
          'goldens/email-desktop-${dark ? 'dark' : 'light'}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final dark in [false, true]) {
    testWidgets('email forms fit mobile in $dark mode', (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final screen in [
        const EmailAccountScreen(),
        const ForgotPasswordScreen(),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: screen,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SingleChildScrollView), findsOneWidget);
        expect(find.text('邮箱地址'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
  testWidgets('failed account load blocks mail actions and retry recovers', (
    tester,
  ) async {
    var loads = 0, requests = 0;
    final actions = EmailAccountActions(
      status: () async {
        if (loads++ == 0) throw Exception('offline');
        return {'bound': false};
      },
      request: (e, p, i, c) async {
        requests++;
        return {};
      },
      confirm: (r, b) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(home: EmailAccountScreen(actions: actions)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('重新加载邮箱信息'));
    await tester.tap(find.text('重新加载邮箱信息'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNotNull,
    );
    expect(requests, 0);
  });
  testWidgets(
    'mail request is single flight, wrong code preserves input, editing invalidates proof',
    (tester) async {
      var requests = 0, confirms = 0;
      final pending = Completer<Map<String, dynamic>>();
      final actions = EmailAccountActions(
        status: () async => {'bound': false},
        request: (e, p, i, c) {
          requests++;
          expect(e, 'person@example.com');
          expect(p, 'Existing-password-123');
          return pending.future;
        },
        confirm: (r, b) async {
          confirms++;
          throw ApiException('验证码不正确或已失效，请重新获取');
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: EmailAccountScreen(actions: actions)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(field('当前密码'), 'Existing-password-123');
      await tester.enterText(field('邮箱地址'), 'person@example.com');
      await tester.tap(find.text('获取验证码'));
      await tester.pump();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(requests, 1);
      pending.complete({
        'request_id': 'fixture-id',
        'resend_after': 60,
        'message': '请查收验证邮件',
      });
      await tester.pumpAndSettle();
      await tester.enterText(field('邮箱验证码'), '123456');
      await tester.ensureVisible(find.text('确认绑定邮箱'));
      await tester.tap(find.text('确认绑定邮箱'));
      await tester.pumpAndSettle();
      expect(confirms, 1);
      expect(find.text('验证码不正确或已失效，请重新获取'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('邮箱验证码')).controller!.text,
        '123456',
      );
      await tester.enterText(field('邮箱地址'), 'changed@example.com');
      await tester.pump();
      expect(tester.widget<TextField>(field('邮箱验证码')).controller!.text, '');
      await tester.ensureVisible(find.text('确认绑定邮箱'));
      await tester.tap(find.text('确认绑定邮箱'));
      await tester.pumpAndSettle();
      expect(confirms, 1);
      expect(find.text('请先获取邮箱验证码'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'bound email and reset are readable with keyboard in $dark mode',
      (tester) async {
        tester.view.physicalSize = const Size(390, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final actions = EmailAccountActions(
          status: () async => {
            'bound': true,
            'masked_email': 'pe***@example.com',
          },
          request: (e, p, i, c) async => {},
          confirm: (r, b) async => null,
        );
        for (final reset in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              home: RepaintBoundary(
                key: const ValueKey('email-page'),
                child: EmailAccountScreen(reset: reset, actions: actions),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (!reset) {
            expect(field('新邮箱验证码'), findsOneWidget);
            expect(field('原邮箱验证码'), findsOneWidget);
          }
          await expectLater(
            find.byKey(const ValueKey('email-page')),
            matchesGoldenFile(
              'goldens/email-${reset ? 'reset' : 'change'}-${dark ? 'dark' : 'light'}.png',
            ),
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pumpAndSettle();
          final label = reset ? '设置新密码' : '确认更换邮箱';
          await tester.ensureVisible(find.text(label));
          await tester.pumpAndSettle();
          expect(tester.getRect(find.text(label)).bottom, lessThan(481));
          expect(tester.takeException(), isNull);
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }
  testWidgets(
    'new registration uses graphical and mailbox verification before creating account',
    (tester) async {
      var sends = 0, registrations = 0;
      Api.instance.network.reset();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const LoginScreen()),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('创建一个账号'));
          await tester.tap(find.text('创建一个账号'));
          await tester.pumpAndSettle();
          await tester.enterText(field('账号'), 'fictional_user');
          await tester.enterText(field('密码'), 'Fictional-password-123');
          await tester.enterText(field('确认密码'), 'Fictional-password-123');
          await tester.enterText(field('邮箱地址'), 'new@example.com');
          await tester.enterText(field('验证码'), 'abcd');
          await tester.ensureVisible(find.text('获取邮箱验证码'));
          await tester.tap(find.text('获取邮箱验证码'));
          await tester.pumpAndSettle();
          expect(sends, 1);
          await tester.enterText(field('邮箱验证码'), '123456');
          // 注册前必须先读完并同意《隐私说明》(数据存储于境外的告知与同意)。
          await acceptPrivacyConsent(tester);
          await tester.ensureVisible(find.text('注册'));
          await tester.tap(find.text('注册'));
          await tester.pumpAndSettle();
          expect(registrations, 1);
          expect(find.text('用户名已被占用'), findsOneWidget);
          expect(
            tester.widget<TextField>(field('邮箱验证码')).controller!.text,
            '123456',
          );
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          final path = req.url.path;
          if (path == '/api/auth/captcha') {
            return http.Response(
              jsonEncode({
                'id': 'graphic-fixture',
                'svg': '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="44"><rect width="120" height="44" fill="white"/></svg>',
              }),
              200,
            );
          }
          final body = jsonDecode(req.body) as Map;
          if (path == '/api/auth/email/register') {
            sends++;
            expect(body['captcha_id'], 'graphic-fixture');
            expect(body['captcha_code'], 'abcd');
            return http.Response(
              jsonEncode({'request_id': 'mail-fixture', 'resend_after': 60}),
              200,
            );
          }
          if (path == '/api/auth/register') {
            registrations++;
            expect(body['email'], 'new@example.com');
            expect(body['request_id'], 'mail-fixture');
            expect(body['code'], '123456');
            return http.Response(
              jsonEncode({'error': '用户名已被占用'}),
              409,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          throw StateError('Unexpected request');
        }),
      );
    },
  );
  testWidgets(
    'password recovery asks for captcha and preserves email through failure',
    (tester) async {
      Api.instance.network.reset();
      var requests = 0;
      final actions = EmailAccountActions(
        status: () async => {},
        request: (e, p, id, code) async {
          requests++;
          expect(e, 'recover@example.com');
          expect(id, 'reset-graphic');
          expect(code, 'abcd');
          throw ApiException('今天的验证邮件已达到上限');
        },
        confirm: (r, b) async => null,
      );
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLightTheme(),
              home: EmailAccountScreen(reset: true, actions: actions),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(field('邮箱地址'), 'recover@example.com');
          await tester.tap(find.text('获取验证码'));
          await tester.pumpAndSettle();
          expect(requests, 0);
          expect(find.text('请输入图形验证码'), findsOneWidget);
          await tester.enterText(field('图形验证码'), 'abcd');
          await tester.tap(find.text('继续'));
          await tester.pumpAndSettle();
          expect(requests, 1);
          expect(find.text('今天的验证邮件已达到上限'), findsOneWidget);
          expect(
            tester.widget<TextField>(field('邮箱地址')).controller!.text,
            'recover@example.com',
          );
          expect(tester.takeException(), isNull);
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 'reset-graphic',
              'svg': '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="44"><rect width="120" height="44" fill="white"/></svg>',
            }),
            200,
          ),
        ),
      );
    },
  );
  for (final dark in [false, true]) {
    testWidgets('my groups and DDL empty state render in $dark theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Api.instance.network.reset();
      await http.runWithClient(
        () async {
          for (final screen in [const SettingsScreen(), const DdlScreen()]) {
            final name = screen is SettingsScreen ? 'my' : 'ddl';
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                home: RepaintBoundary(
                  key: const ValueKey('page'),
                  child: screen,
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (name == 'my') {
              await expectLater(
                find.byKey(const ValueKey('page')),
                matchesGoldenFile(
                  'goldens/email-my-${dark ? 'dark' : 'light'}.png',
                ),
              );
            }
            expect(tester.takeException(), isNull);
            if (name == 'ddl') {
              expect(find.text('这一天没有到期的 DDL 🎀'), findsOneWidget);
              expect(find.text('你这一天没有任务'), findsNothing);
            }
            await tester.pumpWidget(const SizedBox());
          }
        },
        () => MockClient((req) async {
          final body = switch (req.url.path) {
            '/api/account/email' => {'bound': false, 'enabled': true},
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
  testWidgets(
    'binding updates an already mounted my page without reopening it',
    (tester) async {
      Api.instance.network.reset();
      var bound = false;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()),
          );
          await tester.pumpAndSettle();
          expect(find.text('给账号留一份安心'), findsOneWidget);
          await Api.instance.bindEmail({'fixture': true});
          await tester.pumpAndSettle();
          expect(find.text('给账号留一份安心'), findsNothing);
          expect(find.text('pe***@example.com'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          if (req.method == 'POST') {
            bound = true;
            return http.Response('{}', 200);
          }
          final body = switch (req.url.path) {
            '/api/account/email' => {
              'bound': bound,
              'masked_email': bound ? 'pe***@example.com' : null,
              'enabled': true,
            },
            '/api/me' => {'username': 'fictional_user'},
            '/api/stats' => {'lists': 0, 'todos': 0, 'done': 0, 'courses': 0},
            _ => [],
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );
    },
  );
}
