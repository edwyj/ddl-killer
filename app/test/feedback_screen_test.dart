import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/feedback_screen.dart';

void main() {
  testWidgets(
    'failed feedback preserves input with keyboard and repeated submits use one request key',
    (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final inputs = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: FeedbackFormScreen(
            submit: (body) async {
              inputs.add(body);
              throw Exception('offline');
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('feedback-title')),
        '键盘问题',
      );
      await tester.enterText(
        find.byKey(const ValueKey('feedback-description')),
        '打开键盘后输入框消失',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.ensureVisible(find.text('提交反馈'));
      await tester.tap(find.text('提交反馈'));
      await tester.pumpAndSettle();
      expect(inputs.length, 1);
      expect(find.text('键盘问题'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('提交反馈'));
      await tester.tap(find.text('提交反馈'));
      await tester.pumpAndSettle();
      expect(inputs.length, 2);
      expect(inputs[0]['requestKey'], inputs[1]['requestKey']);
    },
  );
  testWidgets(
    'school contribution guides sample collection and requires school name',
    (tester) async {
      var sent = false;
      await tester.pumpWidget(
        MaterialApp(
          home: FeedbackFormScreen(
            initialType: 'school',
            submit: (body) async {
              sent = true;
              return {'ok': true};
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('feedback-title')),
        '希望支持我的学校',
      );
      await tester.enterText(
        find.byKey(const ValueKey('feedback-description')),
        '课表样本',
      );
      await tester.ensureVisible(find.text('提交反馈'));
      await tester.tap(find.text('提交反馈'));
      await tester.pumpAndSettle();
      expect(sent, false);
      expect(find.text('请填写学校名称'), findsOneWidget);
    },
  );
}
