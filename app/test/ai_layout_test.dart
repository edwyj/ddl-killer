import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';

import 'ai_advanced_planner_test.dart' show AdvancedFixture;

void main() {
  for (final width in [320.0, 360.0, 390.0, 1200.0]) {
    testWidgets(
      'actual planner presentation width=$width with keyboard and larger text',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        SharedPreferences.setMockInitialValues({
          'ai_planner_intro_seen_v1': true,
        });
        final repo = AdvancedFixture();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showAiPlannerSheet(context, repository: repo),
                  child: const Text('打开助手'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开助手'));
        await tester.pumpAndSettle();
        expect(
          find.byType(DraggableScrollableSheet),
          width < 600 ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(Dialog),
          width >= 600 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
        if (width < 600) {
          final before = tester.getSize(find.byType(AiPlannerSheet)).height;
          await tester.drag(find.byType(ListView).first, const Offset(0, -140));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byType(AiPlannerSheet)).height,
            greaterThan(before),
          );
        }
        await tester.enterText(
          find.byKey(const ValueKey('ai-planner-input')),
          '合成多行输入，保留这段文字',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('ai-planner-input')))
              .controller!
              .text,
          '合成多行输入，保留这段文字',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('生成安排'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('写报告'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AiPlannerSheet), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
