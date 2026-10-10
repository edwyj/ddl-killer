import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/login_screen.dart';
import 'package:plan_app/widgets/privacy_consent_dialog.dart';

import 'privacy_consent_flow.dart';

/// 注册前的《隐私说明》同意项：它是"数据存储在境外"的告知与同意(PIPL 第 39 条)，
/// 不能被顺手删掉，所以固定在这里。登录不该追问老用户同一件事。
///
/// 2026-10-08 改成：点勾选框先弹出全文，滑到底才能同意——所以下面钉的是
/// "读不完就点不动"，而不只是"有没有这个勾选框"。
void main() {
  setUpAll(() async {
    // 测试默认不加载 pubspec 里声明的字体，不显式装一遍，golden 里全是豆腐块。
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
  });

  void useTallViewport(WidgetTester tester) {
    // 注册表单很长，默认 800x600 里同意项会被挤出可视区，点不中。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> tapCreateAccount(WidgetTester tester) async {
    await tester.ensureVisible(find.text('创建一个账号'));
    await tester.tap(find.text('创建一个账号'));
    await tester.pump();
  }

  Future<void> openRegisterForm(WidgetTester tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();
    await tapCreateAccount(tester);
  }

  Future<void> tapRegister(WidgetTester tester) async {
    await tester.ensureVisible(find.widgetWithText(FilledButton, '注册'));
    await tester.tap(find.widgetWithText(FilledButton, '注册'));
    await tester.pump();
  }

  bool agreeEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(policyAgreeButton()).onPressed != null;

  testWidgets('login never asks returning users to accept it again', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();
    expect(find.textContaining('我已阅读并同意'), findsNothing);
    expect(find.byType(PrivacyConsentDialog), findsNothing);
  });

  testWidgets('register needs a full read-through, not just a tick', (
    tester,
  ) async {
    await openRegisterForm(tester);
    expect(find.textContaining('我已阅读并同意'), findsOneWidget);

    // 不勾选直接提交：先被同意项拦住。
    await tester.enterText(find.byType(TextField).first, 'student');
    await tester.enterText(find.byType(TextField).at(1), 'Example-password');
    await tapRegister(tester);
    expect(find.text('请先阅读并同意《隐私说明》'), findsOneWidget);

    // 点勾选框不是打勾，而是弹出全文。
    await tester.ensureVisible(consentTile());
    await tester.tap(consentCheckbox());
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyConsentDialog), findsOneWidget);
    // 正文确实进来了，出境那一节就在里面。
    expect(find.textContaining('甲骨文云'), findsWidgets);

    // 还没读到底：按钮点不动，勾选框也还没打上。
    expect(agreeEnabled(tester), isFalse);
    await tester.tap(policyAgreeButton());
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyConsentDialog), findsOneWidget);

    // 随便划一点不算读完。
    await tester.drag(policyBody(), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(agreeEnabled(tester), isFalse);

    // 读到底之后才能同意。
    await scrollPolicyToEnd(tester);
    expect(agreeEnabled(tester), isTrue);
    await tester.tap(policyAgreeButton());
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyConsentDialog), findsNothing);
    expect(tester.widget<CheckboxListTile>(consentTile()).value, isTrue);

    // 同意项放行后，拦人的应当是后面的邮箱验证码校验。
    await tapRegister(tester);
    expect(find.text('请先阅读并同意《隐私说明》'), findsNothing);
    expect(find.text('请先验证邮箱，并填写邮件中的6位验证码'), findsOneWidget);
  });

  testWidgets('取消勾选后再勾回来不必重读一遍', (tester) async {
    await openRegisterForm(tester);
    await acceptPrivacyConsent(tester);
    expect(tester.widget<CheckboxListTile>(consentTile()).value, isTrue);

    await tester.tap(consentCheckbox());
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(consentTile()).value, isFalse);

    // 误触取消之后重新勾选，不该再被全文拦一次。
    await tester.tap(consentCheckbox());
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyConsentDialog), findsNothing);
    expect(tester.widget<CheckboxListTile>(consentTile()).value, isTrue);
  });

  testWidgets('全文一屏放得下时不能锁死同意', (tester) async {    // 正文比窗口矮时不会有任何滚动事件；只靠滚动监听的话这道门就是死路。
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) =>
                      const PrivacyConsentDialog(debugContentHeight: 4000),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(policyAgreeButton(), findsOneWidget);
    expect(agreeEnabled(tester), isTrue);
    await tester.tap(policyAgreeButton());
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyConsentDialog), findsNothing);
  });

  // 弹窗在 Beta 通道里看不到（注册入口被编译期剔除），发布前只能靠这个看外观。
  testWidgets('隐私说明弹窗的外观（读到底前后）', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansSC',
          fontFamilyFallback: const ['NotoColorEmoji'],
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const RepaintBoundary(
                    key: ValueKey('dialog'),
                    child: PrivacyConsentDialog(),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('dialog')),
      matchesGoldenFile('goldens/privacy-consent-top.png'),
    );
    await scrollPolicyToEnd(tester);
    await expectLater(
      find.byKey(const ValueKey('dialog')),
      matchesGoldenFile('goldens/privacy-consent-bottom.png'),
    );
  });
}
