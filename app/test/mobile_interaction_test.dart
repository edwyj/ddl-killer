import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';
import 'package:plan_app/widgets/week_view.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/calendar_navigation_bar.dart';

void main() {
  for (final width in [320.0, 390.0, 1440.0, 2560.0]) {
    testWidgets('calendar date centers between edge controls at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: CalendarNavigationBar(
              title: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('第5周', style: TextStyle(fontSize: 17)),
                    Text('9月28日 - 10月4日', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              viewMenu: IconButton(
                tooltip: '切换视图',
                onPressed: () {},
                icon: const Icon(Icons.apps),
              ),
              onPrevious: () {},
              onNext: () {},
              onToday: () {},
            ),
          ),
        ),
      );
      final next = tester.getRect(find.byTooltip('下一段日期'));
      final menu = tester.getRect(find.byTooltip('切换视图'));
      final today = tester.getRect(find.byTooltip('回到今天'));
      expect(
        menu.left - next.right,
        inInclusiveRange(0, 6),
        reason: 'The view menu belongs next to the next-date arrow, not the screen edge',
      );
      final previous = tester.getRect(find.byTooltip('上一段日期'));
      expect(previous.left, closeTo(8, 0.1));
      expect(today.right, closeTo(width - 8, 0.1));
      expect(
        menu.center.dx - next.center.dx,
        closeTo(today.center.dx - menu.center.dx, 0.1),
      );
      expect(
        tester.getCenter(find.text('第5周')).dx,
        closeTo((previous.right + next.left) / 2, 0.1),
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('date and arrows sit left with view controls on the right', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: CalendarNavigationBar(
            title: const Text('9月28日 - 10月4日'),
            viewMenu: const Icon(Icons.grid_view),
            onPrevious: () {},
            onNext: () {},
            onToday: () {},
          ),
        ),
      ),
    );
    final title = tester.getCenter(
      find.byKey(const ValueKey('calendar-date-group')),
    );
    final left = tester.getCenter(find.byTooltip('上一段日期'));
    final right = tester.getCenter(find.byTooltip('下一段日期'));
    final menu = tester.getCenter(find.byIcon(Icons.grid_view));
    expect(title.dx, lessThan(195));
    expect(left.dx, lessThan(title.dx));
    expect(right.dx, greaterThan(title.dx));
    expect(menu.dx, greaterThan(right.dx));
    final date = tester.getRect(find.text('9月28日 - 10月4日'));
    expect(
      date.left - tester.getRect(find.byTooltip('上一段日期')).right,
      greaterThanOrEqualTo(12),
    );
    expect(
      tester.getRect(find.byTooltip('下一段日期')).left - date.right,
      greaterThanOrEqualTo(12),
    );
  });
  testWidgets('diagonal week swipe moves both axes in one gesture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekView(
            days: List.generate(
              7,
              (i) =>
                  WeekDay(date: '2026-10-0${i + 1}', weekday: i + 1, items: []),
            ),
            todayStr: '',
            onTapEmpty: (_, _, _) {},
            onTapItem: (_, _) {},
          ),
        ),
      ),
    );
    final scrolls = tester.widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    final horizontal = scrolls
        .singleWhere((s) => s.scrollDirection == Axis.horizontal)
        .controller!;
    final vertical = scrolls
        .singleWhere((s) => s.scrollDirection == Axis.vertical)
        .controller!;
    await tester.dragFrom(const Offset(270, 450), const Offset(-100, -180));
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(50));
    expect(vertical.offset, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('planner input stays above a tall keyboard', (tester) async {
    SharedPreferences.setMockInitialValues({'ai_planner_intro_seen_v1': true});
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAiPlannerSheet(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('ai-planner-input'));
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(350));
    expect(tester.getRect(input).top, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
