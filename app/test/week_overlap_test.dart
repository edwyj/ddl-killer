import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/week_view.dart';
import 'package:plan_app/widgets/timeline_layout.dart';

TimelineItem item(String title, int start, int end) => TimelineItem(
  type: 'task',
  title: title,
  startMin: start,
  endMin: end,
  color: '#5C8DEF',
);

Future<void> mount(
  WidgetTester tester,
  List<TimelineItem> items, {
  int days = 1,
  void Function(String, TimelineItem)? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: WeekView(
          days: List.generate(
            days,
            (i) => WeekDay(
              date: '2026-09-${14 + i}',
              weekday: i + 1,
              items: i == 0 ? items : [],
            ),
          ),
          todayStr: '',
          startHour: 7,
          onTapEmpty: (_, _, _) {},
          onTapItem: onTap ?? (_, _) {},
        ),
      ),
    ),
  );
}

void main() {
  test('dense connected groups preserve all tasks and separate adjacent groups', () {
    final tasks = [item('A',420,600), item('B',420,460), item('C',430,450),
      item('D',460,480), item('E',600,660)];
    final layout = layoutTimeline(tasks, 2);
    final summary = layout.singleWhere((p) => p.item == null);
    expect(summary.hiddenCount, 3);
    expect(summary.group, containsAll(tasks.take(4)));
    expect(summary.startMin, 420);
    expect(summary.endMin, 480);
    expect(layout.last.item, same(tasks.last));
    expect(layout.last.columns, 1);
    final reversed = layoutTimeline(tasks.reversed.toList(), 2);
    expect(reversed.map((p) => p.item?.title), layout.map((p) => p.item?.title));
  });

  testWidgets('short blocks and clipped morning blocks render without overflow', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, [item('Morning', 360, 450), item('Tiny',421,425),
      item('Third',422,426), item('Next',450,451)], days: 7);
    expect(find.text('+2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlapping tasks occupy separate fixed columns', (
    tester,
  ) async {
    await mount(tester, [item('A', 420, 540), item('B', 450, 570)]);
    expect(
      tester.getRect(find.text('A')).right,
      lessThan(tester.getRect(find.text('B')).left),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('week overflow opens every item and preserves edit callback', (
    tester,
  ) async {
    TimelineItem? tapped;
    final tasks = [
      item('A', 420, 540),
      item('B', 430, 530),
      item('C', 440, 520),
    ];
    await mount(tester, tasks, days: 7, onTap: (_, it) => tapped = it);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('C'), findsNothing);
    await tester.tap(find.text('+2'));
    await tester.pumpAndSettle();
    expect(find.text('这一组的全部安排'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    await tester.tap(find.text('C'));
    await tester.pumpAndSettle();
    expect(tapped, same(tasks[2]));
    expect(find.text('这一组的全部安排'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('day shows three lanes and adjacent times reuse lanes', (
    tester,
  ) async {
    await mount(tester, [
      item('A', 420, 600),
      item('B', 420, 480),
      item('C', 420, 480),
      item('D', 480, 540),
      item('E', 480, 540),
    ]);
    expect(find.textContaining('+'), findsNothing);
    expect(
      tester.getRect(find.text('B')).left,
      tester.getRect(find.text('D')).left,
    );
    expect(
      tester.getRect(find.text('C')).left,
      tester.getRect(find.text('E')).left,
    );
    expect(tester.takeException(), isNull);
  });
}
