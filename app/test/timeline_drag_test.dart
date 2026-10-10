import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/week_view.dart';

void main() {
  const item = TimelineItem(
    type: 'task',
    id: 7,
    title: '拖动任务',
    startMin: 480,
    endMin: 540,
    color: '#008080',
  );
  Future<void> mount(
    WidgetTester tester,
    List<Object> moves, {
    TimelineItem task = item,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekView(
            days: [
              WeekDay(date: '2030-01-01', weekday: 2, items: [task]),
              const WeekDay(date: '2030-01-02', weekday: 3, items: []),
            ],
            todayStr: '2030-01-01',
            hourHeight: 60,
            onTapEmpty: (_, _, _) {},
            onTapItem: (_, _) {},
            onMoveItem: (date, task, start, end) async {
              moves.add([date, task.id!, start, end]);
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
    'mouse moves across dates and snaps time while preserving duration',
    (tester) async {
      final moves = <Object>[];
      await mount(tester, moves);
      final pos = tester.getCenter(find.text('拖动任务'));
      final drag = await tester.startGesture(
        pos,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveTo(pos + const Offset(383, 47));
      await tester.pump();
      expect(find.textContaining('08:45'), findsWidgets);
      await drag.up();
      await tester.pumpAndSettle();
      expect(moves, [
        ['2030-01-02', 7, 525, 585],
      ]);
    },
  );
  testWidgets('touch requires long press and preserves duration', (
    tester,
  ) async {
    final moves = <Object>[];
    await mount(tester, moves);
    final pos = tester.getCenter(find.text('拖动任务'));
    final drag = await tester.startGesture(pos);
    await tester.pump(const Duration(milliseconds: 600));
    await drag.moveBy(const Offset(0, 32));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves, [
      ['2030-01-01', 7, 510, 570],
    ]);
  });
  testWidgets(
    'long press uses a lifted task preview and a source placeholder',
    (tester) async {
      final moves = <Object>[];
      await mount(tester, moves);
      final drag = await tester.startGesture(
        tester.getCenter(find.text('拖动任务')),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.byKey(const ValueKey('drag-origin-placeholder')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('drag-preview-card')), findsOneWidget);
      expect(find.text('01月01日 08:00–09:00'), findsOneWidget);

      final preview = tester.widget<Container>(
        find.byKey(const ValueKey('drag-preview-card')),
      );
      final decoration = preview.decoration! as BoxDecoration;
      expect(decoration.boxShadow, isNotEmpty);

      await drag.cancel();
      await tester.pumpAndSettle();
    },
  );
  testWidgets('touch swipe scrolls without changing a task', (tester) async {
    final moves = <Object>[];
    await mount(tester, moves);
    await tester.drag(find.text('拖动任务'), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });
  testWidgets('dropping outside grid cancels', (tester) async {
    final moves = <Object>[];
    await mount(tester, moves);
    final drag = await tester.startGesture(
      tester.getCenter(find.text('拖动任务')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    await drag.moveTo(const Offset(5, 200));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });
  testWidgets('course blocks cannot be dragged', (tester) async {
    final moves = <Object>[];
    await mount(
      tester,
      moves,
      task: const TimelineItem(
        type: 'class',
        title: '课程',
        startMin: 480,
        endMin: 540,
        color: '#008080',
      ),
    );
    final drag = await tester.startGesture(
      tester.getCenter(find.text('课程')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 80));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });
  testWidgets('drag at viewport edge scrolls toward later times', (
    tester,
  ) async {
    final moves = <Object>[];
    await mount(tester, moves);
    final drag = await tester.startGesture(
      tester.getCenter(find.text('拖动任务')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    await drag.moveTo(const Offset(200, 580));
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scroll.position.pixels;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(scroll.position.pixels, greaterThan(before));
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(moves, isEmpty);
  });
  testWidgets('save failure leaves original schedule and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeekView(
            days: [
              const WeekDay(date: '2030-01-01', weekday: 2, items: [item]),
            ],
            todayStr: '2030-01-01',
            hourHeight: 60,
            onTapEmpty: (_, _, _) {},
            onTapItem: (_, _) {},
            onMoveItem: (_, _, _, _) async {
              attempts++;
              throw Exception('network');
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      final drag = await tester.startGesture(
        tester.getCenter(find.text('拖动任务')),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveBy(const Offset(0, 40));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }
    expect(attempts, 2);
    expect(find.text('调整时间失败，已保留原排期，请重试'), findsOneWidget);
    expect(find.text('08:00–09:00'), findsOneWidget);
  });

  testWidgets(
    'end of day clamps on quarter hour without shortening odd duration',
    (tester) async {
      final moves = <Object>[];
      const odd = TimelineItem(
        type: 'task',
        id: 9,
        title: '65分钟',
        startMin: 480,
        endMin: 545,
        color: '#008080',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeekView(
              days: [
                const WeekDay(date: '2030-01-01', weekday: 2, items: [odd]),
              ],
              todayStr: '2030-01-01',
              hourHeight: 20,
              startHour: 0,
              onTapEmpty: (_, _, _) {},
              onTapItem: (_, _) {},
              onMoveItem: (date, task, start, end) async {
                moves.add([start, end]);
              },
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.text('65分钟')),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveTo(const Offset(200, 532));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(moves, [
        [1365, 1430],
      ]);
    },
  );
}
