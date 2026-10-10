import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/task_editor.dart';
import 'package:plan_app/ddl_postponement.dart';
import 'package:plan_app/widgets/postpone_ddl.dart';

void main() {
  testWidgets('injected future clock is used when confirming postponement', (
    tester,
  ) async {
    final clock = DateTime(2030, 1, 3, 8);
    Map<String, dynamic>? saved;
    const task = InboxTask(
      id: 999,
      title: '示例截止事项',
      dueDate: '2030-01-02',
      dueTime: 1080,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPostponeDdl(
                context,
                task,
                now: () => clock,
                onSave: (body) async {
                  saved = body;
                },
              ),
              child: const Text('打开顺延'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开顺延'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认顺延'));
    await tester.pumpAndSettle();
    expect(saved, {
      'due_date': '2030-01-04',
      'due_time': 1080,
      'reminder_at': null,
    });
    expect(find.text('确认顺延'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'postponement retains deadline time and moves reminder, never the calendar',
    () {
      final task = InboxTask(
        id: 1,
        title: '任务',
        dueDate: '2030-01-30',
        dueTime: 1080,
        reminderAt: DateTime(2030, 1, 30, 17).toUtc().toIso8601String(),
        schedule: const {
          'date': '2030-01-29',
          'start_min': 600,
          'end_min': 660,
        },
      );
      expect(
        postponedDdlPatch(
          task,
          DateTime(2030, 2, 2),
          now: DateTime(2030, 2, 1, 12),
        ),
        {
          'due_date': '2030-02-02',
          'due_time': 1080,
          'reminder_at': DateTime(2030, 2, 2, 17).toUtc().toIso8601String(),
        },
      );
    },
  );

  test('overdue-only eligibility and future deadline validation', () {
    final now = DateTime(2030, 2, 1, 12);
    const overdue = InboxTask(
      id: 1,
      title: '任务',
      dueDate: '2030-01-31',
      dueTime: 600,
    );
    expect(canPostponeDdl(overdue, now: now), isTrue);
    for (final task in [
      const InboxTask(id: 1, title: '完成', dueDate: '2020-01-01', done: true),
      const InboxTask(id: 2, title: '无日期'),
      const InboxTask(id: 3, title: '未来', dueDate: '2030-02-02'),
      const InboxTask(id: 4, title: '今天无时刻', dueDate: '2030-02-01'),
    ]) {
      expect(canPostponeDdl(task, now: now), isFalse);
      expect(
        () => postponedDdlPatch(task, DateTime(2030, 2, 2), now: now),
        throwsArgumentError,
      );
    }
    expect(
      () => postponedDdlPatch(overdue, now, now: now),
      throwsArgumentError,
    );
    expect(
      () => postponedDdlPatch(overdue, DateTime(2030, 1, 31), now: now),
      throwsArgumentError,
    );
  });

  test(
    'date-only deadline can move to today; expired shifted reminder is cleared',
    () {
      final patch = postponedDdlPatch(
        InboxTask(
          id: 1,
          title: '任务',
          dueDate: '2030-01-31',
          reminderAt: DateTime(2030, 1, 31, 8).toUtc().toIso8601String(),
        ),
        DateTime(2030, 2, 1),
        now: DateTime(2030, 2, 1, 12),
      );
      expect(patch, {
        'due_date': '2030-02-01',
        'due_time': null,
        'reminder_at': null,
      });
    },
  );

  testWidgets(
    'custom days survive a failed request and retry sends only DDL fields',
    (tester) async {
      final bodies = <Map>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: PostponeDdlButton(
                  task: InboxTask(
                    id: 42,
                    title: '待顺延',
                    dueDate: '2020-01-01',
                    dueTime: 600,
                    schedule: {
                      'date': '2020-01-01',
                      'start_min': 300,
                      'end_min': 360,
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('顺延'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '3');
          await tester.pump();
          await tester.tap(find.text('确认顺延'));
          await tester.pumpAndSettle();
          expect(find.text('暂时无法保存'), findsOneWidget);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '3',
          );
          await tester.tap(find.text('确认顺延'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(bodies.length, 2);
          expect(bodies[0], bodies[1]);
          final target = DateTime.now().add(const Duration(days: 3));
          expect(
            bodies[0]['due_date'],
            '${target.year}-${target.month.toString().padLeft(2, '0')}-${target.day.toString().padLeft(2, '0')}',
          );
          expect(bodies[0]['due_time'], 600);
          expect(
            bodies[0].keys,
            unorderedEquals(['due_date', 'due_time', 'reminder_at']),
          );
        },
        () => MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/inbox/42');
          bodies.add(jsonDecode(request.body) as Map);
          return http.Response(
            jsonEncode(bodies.length == 1 ? {'error': '暂时无法保存'} : {'ok': true}),
            bodies.length == 1 ? 400 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );

  testWidgets('future and completed tasks do not show the action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PostponeDdlButton(
                task: InboxTask(id: 1, title: '未来', dueDate: '2099-01-01'),
              ),
              PostponeDdlButton(
                task: InboxTask(
                  id: 2,
                  title: '完成',
                  dueDate: '2020-01-01',
                  done: true,
                ),
              ),
              PostponeDdlButton(task: InboxTask(id: 3, title: '无日期')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('顺延'), findsNothing);
  });

  testWidgets(
    'postponing inside the editor retains unsaved task edits until Save',
    (tester) async {
      Map? saved;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showTaskEditor(
                      context,
                      lists: const [],
                      task: const InboxTask(
                        id: 56,
                        title: '原始标题',
                        dueDate: '2020-01-01',
                        dueTime: 600,
                        schedule: {
                          'date': '2020-01-01',
                          'start_min': 480,
                          'end_min': 540,
                        },
                      ),
                    ),
                    child: const Text('编辑'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('编辑'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).first, '未保存的新标题');
          await tester.tap(find.text('顺延 DDL'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认顺延'));
          await tester.pumpAndSettle();
          expect(saved, isNull);
          expect(find.text('未保存的新标题'), findsOneWidget);
          await tester.ensureVisible(find.text('保存'));
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(saved?['title'], '未保存的新标题');
          expect(saved?['due_time'], 600);
          expect(saved?['schedule']['date'], '2020-01-01');
          expect(saved?['due_date'], isNot('2020-01-01'));
        },
        () => MockClient((request) async {
          saved = jsonDecode(request.body) as Map;
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );

  testWidgets('an overdue unfinished task offers manual DDL postponement', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTaskEditor(
                  context,
                  task: const InboxTask(
                    id: 55,
                    title: '过期任务',
                    dueDate: '2020-01-01',
                  ),
                  lists: const [],
                ),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('顺延 DDL'), findsOneWidget);
    }, () => MockClient((_) async => http.Response(jsonEncode([]), 200)));
  });
}
