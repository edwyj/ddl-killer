import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/widgets/privacy_consent_dialog.dart';

/// 注册前那道门怎么过：点勾选框 → 弹出全文 → 滑到底 → 点「同意」。
///
/// 注册相关的测试都走这里，免得各自写一套、UI 一变就各错各的。
/// （不是 *_test.dart，所以不会被当测试文件跑。）

/// 注册表单里的同意项。
Finder consentTile() => find.ancestor(
  of: find.textContaining('我已阅读并同意'),
  matching: find.byType(CheckboxListTile),
);

/// 同意项的勾选框（点它或点整行都会走同一条路）。
Finder consentCheckbox() =>
    find.descendant(of: consentTile(), matching: find.byType(Checkbox));

Future<void> acceptPrivacyConsent(WidgetTester tester) async {
  await tester.ensureVisible(consentTile());
  await tester.tap(consentCheckbox());
  await tester.pumpAndSettle();
  await scrollPolicyToEnd(tester);
  await tester.tap(find.widgetWithText(FilledButton, '同意'));
  await tester.pumpAndSettle();
}

/// 弹窗里的「同意」按钮。
Finder policyAgreeButton() => find.descendant(
  of: find.byType(PrivacyConsentDialog),
  matching: find.byType(FilledButton),
);

/// 弹窗里的正文滚动区。要限定在弹窗内——登录页自身也可能有滚动区。
Finder policyBody() => find.descendant(
  of: find.byType(PrivacyConsentDialog),
  matching: find.byType(SingleChildScrollView),
);

/// 把弹窗里的正文滑到底（一次拖足够远，位置会夹在 maxScrollExtent 上）。
Future<void> scrollPolicyToEnd(WidgetTester tester) async {
  await tester.drag(policyBody(), const Offset(0, -8000));
  await tester.pumpAndSettle();
}
