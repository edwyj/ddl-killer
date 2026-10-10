import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/screens/list_screen.dart';
import 'package:plan_app/plan_bus.dart';
import 'package:plan_app/theme.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/today_agenda_tile.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'overdue Today reminders retain warning and postpone without changing card size',
    (tester) async {
      final now = DateTime.now();
      final task = InboxTask.fromJson({
        'id': 999,
        'title': '示例已过期截止事项',
        'due_date': DateFormat('yyyy-MM-dd')
            .format(now.subtract(const Duration(days: 1))),
        'due_time': 0,
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Column(
              children: [
                TodayAgendaTile(
                  item: TimelineItem.fromJson({
                    'type': 'class',
                    'title': '示例课程',
                    'start_min': 480,
                    'end_min': 540,
                  }),
                  onOpen: () {},
                  onToggle: null,
                ),
                TodayDeadlineTile(
                  task: task,
                  now: () => now,
                  listColor: Colors.teal,
                  onOpen: () {},
                  onToggle: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cards = tester.getSize(find.byType(Card).first);
      expect(tester.getSize(find.byType(Card).last), cards);
      final warning = tester.widget<Text>(
        find.text(dueLabel(task.dueDate, task.dueTime, now: now)),
      );
      expect(warning.style?.color, const Color(0xFFE05858));
      expect(warning.style?.fontWeight, FontWeight.w700);
      await tester.tap(find.text('顺延'));
      await tester.pumpAndSettle();
      expect(
        find.text('原截止：${dueLabel(task.dueDate, task.dueTime)}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final scale in [1.0, 1.4]) {
    testWidgets(
      'long agenda titles remain compact at $scale and details retain full content',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const title =
            '📚学习记录与资料整理：阅读示例长篇文章《Notes on a Fictional Study Project》，'
            '梳理背景和核心概念，整理笔记并为下一次练习留下一些可调整的时间。';
        const note = '完整的说明只在详情中查看';
        const dueTitle = '今天截止的长任务：$title';
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildLightTheme(),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(390, 844),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: const ListScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final agendaRect = tester.getRect(
              find.ancestor(of: find.text(title), matching: find.byType(Card)),
            );
            for (final label in ['示例课程', dueTitle]) {
              final rect = tester.getRect(
                find.ancestor(
                  of: find.text(label),
                  matching: find.byType(Card),
                ),
              );
              expect(
                rect.left,
                closeTo(agendaRect.left, 0.1),
                reason: 'Today sections should share their left edge',
              );
              expect(
                rect.width,
                closeTo(agendaRect.width, 0.1),
                reason: 'Today sections should share their card width',
              );
              expect(
                rect.height,
                closeTo(agendaRect.height, 0.1),
                reason:
                    'Short courses and long deadlines should share card height',
              );
            }
            expect(
              tester
                  .getSize(
                    find.ancestor(
                      of: find.text(title),
                      matching: find.byType(Card),
                    ),
                  )
                  .height,
              lessThan(160),
            );
            expect(find.textContaining(note), findsNothing);
            expect(
              tester
                  .getSize(
                    find.ancestor(
                      of: find.text(dueTitle),
                      matching: find.byType(Card),
                    ),
                  )
                  .height,
              lessThan(160),
            );
            expect(find.textContaining('示例教学楼'), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.tap(find.text(title));
            await tester.pumpAndSettle();
            final fields = tester
                .widgetList<TextField>(find.byType(TextField))
                .toList();
            expect(
              fields.any((field) => field.controller?.text == title),
              isTrue,
            );
            expect(
              fields.any((field) => field.controller?.text == note),
              isTrue,
            );
            await tester.pumpWidget(const SizedBox());
          },
          () => MockClient(
            (req) async => http.Response(
              jsonEncode(
                req.url.path == '/api/day'
                    ? {
                        'timeline': [
                          {
                            'type': 'class',
                            'title': '示例课程',
                            'room': '示例教学楼',
                            'start_min': 480,
                            'end_min': 540,
                          },
                          {
                            'type': 'task',
                            'id': 1,
                            'title': title,
                            'notes': note,
                            'start_min': 600,
                            'end_min': 660,
                          },
                        ],
                      }
                    : req.url.path == '/api/inbox'
                    ? [
                        {
                          'id': 2,
                          'title': dueTitle,
                          'notes': note,
                          'due_date': DateFormat('yyyy-MM-dd')
                              .format(DateTime.now()),
                        },
                      ]
                    : [],
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
      },
    );
  }
  testWidgets(
    'first agenda failure can recover through a data change without rendering an empty date',
    (tester) async {
      var fail = true;
      final recovery = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: ListScreen()));
          await tester.pumpAndSettle();
          expect(find.text('重试'), findsOneWidget);
          fail = false;
          PlanBus.instance.bump();
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          recovery.complete(http.Response('{"timeline":[]}', 200));
          await tester.pumpAndSettle();
          expect(find.text('今天还没有排好的安排 🎀'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          if (req.url.path == '/api/day') {
            if (fail) throw http.ClientException('fixture offline');
            return recovery.future;
          }
          return http.Response('[]', 200);
        }),
      );
    },
  );
  setUpAll(() async {
    for (final entry in {
      'NotoSansSC': 'assets/fonts/NotoSansSC.ttf',
      'Ahem': 'assets/fonts/NotoSansSC.ttf',
      'NotoColorEmoji': 'assets/fonts/NotoColorEmoji.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Api.instance.network.reset();
  });
  testWidgets(
    'Today shows chronological calendar entries and only unscheduled due reminders',
    (tester) async {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final tasks = [
        {
          'id': 1,
          'title': '已排期任务',
          'due_date': '2099-12-01',
          'schedule': {
            'id': 11,
            'date': today,
            'start_min': 600,
            'end_min': 660,
          },
        },
        {'id': 2, 'title': '今天截止未排期', 'due_date': today},
        {'id': 3, 'title': '已完成截止事项', 'due_date': today, 'done': 1},
        {'id': 4, 'title': '过期任务', 'due_date': '2001-01-01'},
        {
          'id': 5,
          'title': '今天截止已排期',
          'due_date': today,
          'schedule': {
            'id': 13,
            'date': today,
            'start_min': 900,
            'end_min': 960,
          },
        },
      ];
      var done = false;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: ListScreen()));
          await tester.pumpAndSettle();
          for (final title in ['示例课程', '已排期任务', '独立日程', '今天截止未排期']) {
            expect(find.text(title), findsOneWidget);
          }
          expect(find.text('过期任务'), findsNothing);
          expect(find.text('已完成截止事项'), findsNothing);
          expect(find.text('今天截止已排期'), findsOneWidget);
          expect(
            tester.getTopLeft(find.text('示例课程')).dy,
            lessThan(tester.getTopLeft(find.text('已排期任务')).dy),
          );
          expect(
            tester.getTopLeft(find.text('已排期任务')).dy,
            lessThan(tester.getTopLeft(find.text('独立日程')).dy),
          );
          await tester.tap(find.byTooltip('完成「已排期任务」'));
          await tester.pumpAndSettle();
          expect(done, isTrue);
          expect(
            tester.widget<Text>(find.text('已排期任务')).style?.decoration,
            TextDecoration.lineThrough,
          );
          await tester.ensureVisible(find.text('今天截止未排期'));
          await tester.tap(find.byTooltip('完成「今天截止未排期」'));
          await tester.pumpAndSettle();
          expect(tasks[1]['done'], 1);
          expect(find.text('今天截止未排期'), findsNothing);
          expect(find.text('今天截止 · 还未排时间'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          dynamic response;
          switch (req.url.path) {
            case '/api/inbox':
              response = tasks;
            case '/api/lists':
              response = [];
            case '/api/day':
              expect(req.url.queryParameters['date'], today);
              response = {
                'timeline': [
                  {
                    'type': 'task',
                    'id': 12,
                    'title': '独立日程',
                    'start_min': 720,
                    'end_min': 780,
                  },
                  {
                    'type': 'class',
                    'title': '示例课程',
                    'start_min': 480,
                    'end_min': 540,
                  },
                  {
                    'type': 'task',
                    'id': 11,
                    'title': '已排期任务',
                    'start_min': 600,
                    'end_min': 660,
                    'done': done ? 1 : 0,
                  },
                  {
                    'type': 'task',
                    'id': 13,
                    'title': '今天截止已排期',
                    'start_min': 900,
                    'end_min': 960,
                  },
                ],
              };
            case '/api/blocks/11':
              expect(req.method, 'PATCH');
              expect(jsonDecode(req.body)['done'], isTrue);
              done = true;
              response = {'ok': true};
            case '/api/inbox/2':
              expect(req.method, 'PATCH');
              expect(jsonDecode(req.body)['done'], isTrue);
              tasks[1]['done'] = 1;
              response = {'ok': true};
            default:
              throw StateError('Unexpected request ${req.url.path}');
          }
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );
  testWidgets(
    'empty Today describes missing arrangements and add does not force a deadline',
    (tester) async {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: ListScreen()));
          await tester.pumpAndSettle();
          expect(find.text('今天还没有排好的安排 🎀'), findsOneWidget);
          expect(find.text('没有待办'), findsNothing);
          await tester.tap(find.byType(FloatingActionButton));
          await tester.pumpAndSettle();
          expect(find.text('新安排'), findsOneWidget);
          expect(find.text('截止日期'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient(
          (req) async => http.Response(
            jsonEncode(req.url.path == '/api/day' ? {'timeline': []} : []),
            200,
          ),
        ),
      );
    },
  );
  testWidgets(
    'stale refresh cannot replace a newer agenda; resume switches to current date',
    (tester) async {
      var now = DateTime(2030, 1, 3, 23, 58), requests = 0;
      final old = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(home: ListScreen(now: () => now)),
          );
          await tester.pumpAndSettle();
          PlanBus.instance.bump();
          await tester.pump();
          PlanBus.instance.bump();
          await tester.pumpAndSettle();
          expect(find.text('最新安排'), findsOneWidget);
          old.complete(
            http.Response(
              jsonEncode({
                'timeline': [
                  {
                    'type': 'task',
                    'id': 1,
                    'title': '陈旧安排',
                    'start_min': 600,
                    'end_min': 660,
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('陈旧安排'), findsNothing);
          now = DateTime(2030, 1, 4, 0, 1);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          expect(find.text('新一天的安排'), findsOneWidget);
          expect(find.text('最新安排'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          if (req.url.path == '/api/day') {
            requests++;
            if (requests == 2) return old.future;
            return http.Response(
              jsonEncode({
                'timeline': [
                  {
                    'type': 'task',
                    'id': 1,
                    'title': req.url.queryParameters['date'] == '2030-01-04'
                        ? '新一天的安排'
                        : requests > 2
                        ? '最新安排'
                        : '初始安排',
                    'start_min': 600,
                    'end_min': 660,
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('[]', 200);
        }),
      );
    },
  );
  testWidgets(
    'wide desktop Today shares the full-width column of the other lists',
    (tester) async {
      const width = 1400.0;
      tester.view.physicalSize = const Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const ListScreen()),
          );
          await tester.pumpAndSettle();
          final todayCard = tester.getRect(
            find.ancestor(
              of: find.text('示例课程'),
              matching: find.byType(Card),
            ),
          );
          // 今天页曾把内容夹在居中的 760 宽栏里，宽屏两侧留下大片空白。
          expect(
            todayCard.width,
            greaterThan(width * 0.9),
            reason: 'Today should not be clamped into a narrow centred column',
          );
          expect(todayCard.center.dx, closeTo(width / 2, 0.1));

          await tester.tap(find.byIcon(Icons.menu));
          await tester.pumpAndSettle();
          await tester.tap(find.text('收集箱'));
          await tester.pumpAndSettle();
          final listCard = tester.getRect(
            find.ancestor(
              of: find.text('示例清单任务'),
              matching: find.byType(Card),
            ),
          );
          // 对照：同一窗口下的清单卡片同样铺满。注意 Card 的 margin 算在自身
          // 盒子里（清单卡片盒含左右各 12 的 margin，今天卡片盒不含，间距来自
          // ListView 的 16），所以只断言两者都占满窗口，不比精确宽度。
          expect(
            listCard.width,
            greaterThan(width * 0.9),
            reason: 'The other lists already fill the window width',
          );
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          dynamic response;
          switch (req.url.path) {
            case '/api/day':
              response = {
                'timeline': [
                  {
                    'type': 'class',
                    'title': '示例课程',
                    'start_min': 480,
                    'end_min': 540,
                  },
                ],
              };
            case '/api/inbox':
              response = [
                {'id': 1, 'title': '示例清单任务', 'due_date': '2099-12-01'},
              ];
            default:
              response = [];
          }
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );
  for (final dark in [false, true]) {
    for (final width in [390.0, 1200.0]) {
      testWidgets(
        'Today fits $width in $dark theme with long titles and deadlines',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final now = DateTime(2030, 1, 3, 8);
          await http.runWithClient(
            () async {
              await tester.pumpWidget(
                MaterialApp(
                  theme: dark ? buildDarkTheme() : buildLightTheme(),
                  home: RepaintBoundary(
                    key: const ValueKey('today-page'),
                    child: ListScreen(now: () => now),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await expectLater(
                find.byKey(const ValueKey('today-page')),
                matchesGoldenFile(
                  'goldens/today-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
                ),
              );
              await tester.tap(find.text('示例课程'));
              await tester.pumpAndSettle();
              expect(find.text('课程详情'), findsOneWidget);
              await tester.pumpWidget(const SizedBox());
            },
            () => MockClient((req) async {
              return http.Response(
                jsonEncode(
                  req.url.path == '/api/day'
                      ? {
                          'timeline': [
                            {
                              'type': 'class',
                              'title': '示例课程',
                              'start_min': 480,
                              'end_min': 540,
                              'room': '示例教学楼',
                            },
                            {
                              'type': 'task',
                              'id': 1,
                              'title': '📚资料整理：阅读示例文章《Notes on a Fictional Study Project》，梳理背景和核心概念，完成段落练习和项目提纲，然后为下一次学习留下一些可调整的时间',
                              'start_min': 600,
                              'end_min': 660,
                              'notes': '先做最需要专心的部分',
                            },
                            {
                              'type': 'task',
                              'id': 2,
                              'title': '散步',
                              'start_min': 1020,
                              'end_min': 1050,
                              'done': 1,
                            },
                          ],
                        }
                      : req.url.path == '/api/inbox'
                      ? [
                          {
                            'id': 3,
                            'title': '提交示例项目',
                            'due_date': '2030-01-03',
                            'due_time': 1200,
                          },
                          {
                            'id': 4,
                            'title': '补交示例资料',
                            'due_date': '2030-01-03',
                            'due_time': 420,
                          },
                        ]
                      : [],
                ),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          );
        },
      );
    }
  }
}
