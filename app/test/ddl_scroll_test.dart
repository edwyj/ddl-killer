import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:plan_app/screens/ddl_screen.dart';
import 'package:plan_app/models.dart' show dueLabel;
import 'package:plan_app/theme.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'Ahem': 'assets/fonts/NotoSansSC.ttf',
      'NotoSansSC': 'assets/fonts/NotoSansSC.ttf',
      'NotoColorEmoji': 'assets/fonts/NotoColorEmoji.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  Map<String, dynamic> task(int id, {bool done = false}) => {
    'id': id,
    'title': '示例截止事项 $id',
    'done': done ? 1 : 0,
    'due_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
  };

  testWidgets(
    'one vertical gesture collapses calendar before scrolling the first deadline; reverse restores both',
    (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const DdlScreen()),
          );
          await tester.pumpAndSettle();
          final calendar = find.byKey(const ValueKey('ddl-calendar'));
          final first = find.byKey(const ValueKey('ddl-task-1'));
          final full = tester.getSize(calendar).height;
          final inset =
              tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy;
          final gesture = await tester.startGesture(tester.getCenter(first));
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump();
          await gesture.moveBy(const Offset(0, -80));
          await tester.pump();
          final partial = tester.getSize(calendar).height;
          expect(partial, lessThan(full - 30));
          expect(
            tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy,
            closeTo(inset, 1),
          );
          await gesture.moveBy(const Offset(0, -350));
          await tester.pump();
          final week = tester.getSize(calendar).height;
          expect(week, lessThan(partial - 30));
          expect(
            tester.getTopLeft(first).dy,
            lessThan(tester.getBottomLeft(calendar).dy),
          );
          await gesture.moveBy(const Offset(0, 80));
          await tester.pump();
          expect(tester.getSize(calendar).height, closeTo(week, 1));
          await gesture.moveBy(const Offset(0, 350));
          await tester.pump();
          expect(tester.getSize(calendar).height, closeTo(full, 1));
          expect(
            tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy,
            closeTo(inset, 1),
          );
          await gesture.up();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode([for (var id = 1; id <= 16; id++) task(id)]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
    },
  );
  testWidgets(
    'completed heading expands as a whole and unchecking restores the deadline without resetting scroll',
    (tester) async {
      var done = true, writes = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const DdlScreen()),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('切到周视图'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('已完成'));
          await tester.pumpAndSettle();
          expect(find.text('示例截止事项 2'), findsOneWidget);
          await tester.tap(find.byTooltip('取消完成「示例截止事项 2」'));
          await tester.pumpAndSettle();
          expect(writes, 1);
          expect(find.text('已完成'), findsNothing);
          expect(find.text('示例截止事项 2'), findsOneWidget);
          expect(find.byTooltip('切到月视图'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient((req) async {
          if (req.method == 'PATCH') {
            writes++;
            expect(jsonDecode(req.body)['done'], isFalse);
            done = false;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            jsonEncode([task(1), task(2, done: done)]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
    },
  );
  testWidgets(
    'wheel over toolbar and fast flings share calendar and list scroll',
    (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: buildLightTheme(), home: const DdlScreen()),
          );
          await tester.pumpAndSettle();
          final calendar = find.byKey(const ValueKey('ddl-calendar'));
          final first = find.byKey(const ValueKey('ddl-task-1'));
          final full = tester.getSize(calendar).height;
          final inset =
              tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy;
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: const Offset(100, 28),
              scrollDelta: const Offset(0, 60),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(calendar).height, lessThan(full));
          expect(
            tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy,
            closeTo(inset, 1),
          );
          await tester.fling(
            find.byType(CustomScrollView),
            const Offset(0, -420),
            1500,
          );
          await tester.pumpAndSettle();
          expect(find.byTooltip('切到月视图'), findsOneWidget);
          expect(
            tester.getTopLeft(first).dy,
            lessThan(tester.getBottomLeft(calendar).dy),
          );
          await tester.fling(
            find.byType(CustomScrollView),
            const Offset(0, 1100),
            2500,
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(calendar).height, closeTo(full, 1));
          expect(
            tester.getTopLeft(first).dy - tester.getBottomLeft(calendar).dy,
            closeTo(inset, 1),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient(
          (req) async => http.Response(
            jsonEncode([for (var id = 1; id <= 16; id++) task(id)]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
    },
  );
  for (final date in [
    DateTime(2027, 2, 10),
    DateTime(2026, 10, 7),
    DateTime(2026, 3, 18),
  ]) {
    testWidgets(
      'empty ${date.month} calendar collapses from the date grid and keeps date taps aligned in a narrow pane',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 480, child: DdlScreen(now: () => date)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final calendar = find.byKey(const ValueKey('ddl-calendar'));
          final initial = tester.getSize(calendar).height;
          final gesture = await tester.startGesture(
            tester.getCenter(find.text('${date.day}')),
          );
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump();
          await gesture.moveBy(const Offset(0, -400));
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          expect(tester.getSize(calendar).height, lessThan(initial - 100));
          expect(find.byTooltip('切到月视图'), findsOneWidget);
          await tester.tap(find.text('${date.day + 1}'));
          await tester.pumpAndSettle();
          // New deadline inherits the tapped date, proving the hit map uses the pane width.
          await tester.tap(find.byType(FloatingActionButton));
          await tester.pumpAndSettle();
          expect(
            find.text(
              dueLabel(
                DateFormat('yyyy-MM-dd')
                    .format(date.add(const Duration(days: 1))),
                null,
              ),
            ),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }, () => MockClient((req) async => http.Response('[]', 200)));
      },
    );
  }
  testWidgets(
    'collapsed calendar stays one week across month row count changes',
    (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(home: DdlScreen(now: () => DateTime(2027, 2, 10))),
        );
        await tester.pumpAndSettle();
        final calendar = find.byKey(const ValueKey('ddl-calendar'));
        final initial = tester.getSize(calendar).height;
        await tester.tap(find.byTooltip('切到周视图'));
        await tester.pumpAndSettle();
        final weekHeight = tester.getSize(calendar).height;
        for (var i = 0; i < 3; i++) {
          await tester.fling(calendar, const Offset(280, 0), 1000);
          await tester.pumpAndSettle();
          expect(tester.getSize(calendar).height, closeTo(weekHeight, 1));
          expect(find.byTooltip('切到月视图'), findsOneWidget);
        }
        expect(find.text('2026年 11月'), findsOneWidget);
        await tester.tap(find.byTooltip('切到月视图'));
        await tester.pumpAndSettle();
        expect(tester.getSize(calendar).height, greaterThan(initial + 80));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, () => MockClient((req) async => http.Response('[]', 200)));
    },
  );
  for (final dark in [false, true]) {
    for (final width in [390.0, 1200.0]) {
      testWidgets('DDL month, transition and week render at $width dark=$dark', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final date = DateTime(2026, 10, 6);
        await http.runWithClient(
          () async {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                home: RepaintBoundary(
                  key: const ValueKey('ddl-page'),
                  child: Scaffold(
                    body: DdlScreen(now: () => date),
                    bottomNavigationBar: NavigationBar(
                      height: 72,
                      selectedIndex: 2,
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysHide,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.checklist),
                          label: '',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.calendar_month_outlined),
                          label: '',
                        ),
                        NavigationDestination(
                          icon: Text(
                            'DDL',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          label: '',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          label: '',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final position = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            final full = tester
                .getSize(find.byKey(const ValueKey('ddl-calendar')))
                .height;
            for (final stage in ['month', 'transition', 'week']) {
              if (stage == 'transition') position.jumpTo((full - 82) / 2);
              if (stage == 'week') position.jumpTo(full - 82);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await expectLater(
                find.byKey(const ValueKey('ddl-page')),
                matchesGoldenFile(
                  'goldens/ddl-${width.toInt()}-${dark ? 'dark' : 'light'}-$stage.png',
                ),
              );
            }
            await tester.pumpWidget(const SizedBox());
          },
          () => MockClient(
            (req) async => http.Response(
              jsonEncode([
                for (var id = 1; id <= 8; id++)
                  {
                    'id': id,
                    'title': '示例截止事项 $id',
                    'due_date': '2026-10-06',
                    'done': id == 8 ? 1 : 0,
                  },
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
      });
    }
  }
}
