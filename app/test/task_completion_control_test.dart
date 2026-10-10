import 'dart:ui' show Tristate, CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/task_completion_control.dart';
import 'package:plan_app/widgets/today_agenda_tile.dart';

void main() {
  testWidgets('completion retains keyboard focus and checked semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var done = false, toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TaskCompletionControl(
                done: done,
                color: Colors.teal,
                title: '示例任务',
                onToggle: () => setState(() {
                  done = !done;
                  toggles++;
                }),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final node = tester.getSemantics(find.bySemanticsLabel('完成「示例任务」'));
      expect(node.flagsCollection.isFocused, isNot(Tristate.none));
      expect(node.flagsCollection.isFocused, Tristate.isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('取消完成「示例任务」'))
            .flagsCollection.isChecked,
        CheckedState.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(toggles, 2);
    } finally {
      semantics.dispose();
    }
  });
  for (final width in [390.0, 1200.0]) {
    testWidgets('completion is compact but keeps a 44px target at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TaskCompletionControl(
                done: false,
                color: Colors.teal,
                title: '示例任务',
                onToggle: () => toggles++,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(TaskCompletionControl)),
        const Size(44, 44),
      );
      final mark = find.descendant(
        of: find.byType(TaskCompletionControl),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(mark), Size.square(width < 600 ? 20 : 26));
      final target = tester.getRect(find.byType(TaskCompletionControl));
      await tester.tapAt(target.topLeft + const Offset(3, 3));
      await tester.pump();
      expect(toggles, 1);
      expect(find.byTooltip('完成「示例任务」'), findsOneWidget);
    });
  }
  testWidgets(
    'Today uses the shared completion control and a non-interactive course icon',
    (tester) async {
      var toggles = 0, opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TodayAgendaTile(
                  item: TimelineItem.fromJson({
                    'type': 'class',
                    'title': '示例课程',
                    'start_min': 600,
                    'end_min': 660,
                  }),
                  onOpen: () => opens++,
                  onToggle: () => toggles++,
                ),
                TodayAgendaTile(
                  item: TimelineItem.fromJson({
                    'type': 'task',
                    'id': 1,
                    'title': '示例任务',
                    'start_min': 660,
                    'end_min': 720,
                  }),
                  onOpen: () => opens++,
                  onToggle: () => toggles++,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('课程'), findsNothing);
      expect(find.byIcon(Icons.school_outlined), findsOneWidget);
      expect(find.byType(TaskCompletionControl), findsOneWidget);
      await tester.tap(find.byType(TaskCompletionControl));
      await tester.pump();
      expect(toggles, 1);
      expect(opens, 0);
      await tester.tap(find.byIcon(Icons.school_outlined));
      await tester.pump();
      expect(toggles, 1);
      expect(opens, 1);
    },
  );
}
