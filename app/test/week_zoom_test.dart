import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/week_view.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: WeekView(
            days: List.generate(
              7,
              (i) => WeekDay(
                date: '2030-01-${(i + 1).toString().padLeft(2, '0')}',
                weekday: i + 1,
                items: i == 0
                    ? const [
                        TimelineItem(
                          type: 'task',
                          id: 8,
                          title: '论文写作',
                          startMin: 540,
                          endMin: 660,
                          color: '#9966CC',
                        ),
                      ]
                    : [],
              ),
            ),
            todayStr: '2030-01-01',
            hourHeight: 60,
            startHour: 7,
            onTapEmpty: (_, _, _) {},
            onTapItem: (_, _) {},
          ),
        ),
      ),
    );
  }

  testWidgets('date header stays pinned and follows horizontal movement', (
    tester,
  ) async {
    await mount(tester);
    final before = tester.getTopLeft(find.text('周二'));
    await tester.dragFrom(const Offset(240, 450), const Offset(-65, -240));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.text('周二'));
    expect(after.dy, before.dy);
    expect(after.dx, lessThan(before.dx));
    expect(find.byKey(const ValueKey('week-pinned-header')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final spread in [20.0, 85.0, 120.0, 300.0]) {
    testWidgets(
      'pinch to $spread then pan reaches Sunday with aligned header',
      (tester) async {
        await mount(tester);
        final a = await tester.startGesture(const Offset(150, 350), pointer: 1);
        final b = await tester.startGesture(const Offset(230, 350), pointer: 2);
        await a.moveTo(const Offset(140, 350));
        await tester.pump();
        await b.moveTo(const Offset(240, 350));
        await tester.pump();
        await a.moveTo(Offset(190 - spread, 350));
        await b.moveTo(Offset(190 + spread, 350));
        await tester.pump();
        // At a zoom limit the fingers can still move without changing the grid size.
        await a.moveTo(Offset(210 - spread, 350));
        await b.moveTo(Offset(210 + spread, 350));
        await tester.pump();
        final columns = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_DayColumn',
        );
        expect(
          tester.getCenter(find.text('周一')).dx,
          closeTo(tester.getCenter(columns.first).dx, 0.1),
          reason: 'Header and body must agree even when the zoom limit prevents relayout',
        );
        await a.up();
        await b.up();
        await tester.pumpAndSettle();
        final horizontal = tester
            .widgetList<SingleChildScrollView>(
              find.byType(SingleChildScrollView),
            )
            .singleWhere((v) => v.scrollDirection == Axis.horizontal)
            .controller!;
        final width =
            tester.getCenter(find.text('周二')).dx -
            tester.getCenter(find.text('周一')).dx;
        expect(
          horizontal.position.maxScrollExtent,
          closeTo(width * 7 - 356, 0.1),
          reason: 'Scroll range must use the resized columns, not the previous layout',
        );
        for (var i = 0; i < 14; i++) {
          await tester.dragFrom(const Offset(330, 420), const Offset(-260, 0));
          await tester.pumpAndSettle();
        }
        expect(horizontal.offset, closeTo(width * 7 - 356, 0.1));
        expect(
          tester.getCenter(find.text('周日')).dx,
          closeTo(tester.getCenter(columns.last).dx, 0.1),
        );
        expect(tester.getRect(columns.last).right, closeTo(390, 0.1));
        final header = find.byKey(const ValueKey('week-pinned-header'));
        await tester.tapAt(tester.getCenter(header));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(tester.getCenter(header));
        await tester.pumpAndSettle();
        expect(
          tester.getCenter(find.text('周日')).dx,
          closeTo(tester.getCenter(columns.last).dx, 0.1),
          reason: 'Resetting at the right edge must keep the header aligned after clamping',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final brightness in Brightness.values) {
    testWidgets(
      'pinch reflows calendar but preserves font size in $brightness',
      (tester) async {
        await mount(tester, brightness: brightness);
        final title = find.text('论文写作');
        final font = tester.widget<Text>(title).style!.fontSize;
        final widthBefore =
            tester.getTopLeft(find.text('周二')).dx -
            tester.getTopLeft(find.text('周一')).dx;
        final a = await tester.startGesture(const Offset(130, 330), pointer: 1);
        final b = await tester.startGesture(const Offset(250, 330), pointer: 2);
        await a.moveTo(const Offset(115, 330));
        await tester.pump();
        await b.moveTo(const Offset(265, 330));
        await tester.pump();
        await a.moveTo(const Offset(70, 330));
        await tester.pump();
        await b.moveTo(const Offset(310, 330));
        await tester.pump();
        final widthAfter =
            tester.getTopLeft(find.text('周二')).dx -
            tester.getTopLeft(find.text('周一')).dx;
        expect(widthAfter, greaterThan(widthBefore * 1.2));
        expect(tester.widget<Text>(title).style!.fontSize, font);
        await a.up();
        await b.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final header = find.byKey(const ValueKey('week-pinned-header'));
        await tester.tapAt(tester.getCenter(header));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(tester.getCenter(header));
        await tester.pumpAndSettle();
        final resetWidth =
            tester.getTopLeft(find.text('周二')).dx -
            tester.getTopLeft(find.text('周一')).dx;
        expect(resetWidth, closeTo(widthBefore, 0.1));
      },
    );
  }
  testWidgets(
    'phone pinch fits one to four days and applies anchors before paint',
    (tester) async {
      await mount(tester);
      double dayWidth() =>
          tester.getTopLeft(find.text('周二')).dx -
          tester.getTopLeft(find.text('周一')).dx;
      ScrollController controller(Axis axis) => tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .singleWhere((view) => view.scrollDirection == axis)
          .controller!;
      final a = await tester.startGesture(const Offset(170, 350), pointer: 1);
      final b = await tester.startGesture(const Offset(210, 350), pointer: 2);
      await a.moveTo(const Offset(160, 350));
      await tester.pump();
      await b.moveTo(const Offset(220, 350));
      await tester.pump();
      for (var distance = 50.0; distance <= 330; distance += 20) {
        // Multiple pointer events before one paint must use the same content anchor.
        await a.moveTo(Offset(190 - distance, 350));
        await b.moveTo(Offset(190 + distance, 350));
        await tester.pump();
        final x = controller(Axis.horizontal).offset;
        final y = controller(Axis.vertical).offset;
        final header = tester.getTopLeft(find.text('周二'));
        await tester.pump();
        expect(controller(Axis.horizontal).offset, closeTo(x, 0.01));
        expect(controller(Axis.vertical).offset, closeTo(y, 0.01));
        expect(tester.getTopLeft(find.text('周二')), header);
      }
      expect(dayWidth(), closeTo(390 - 34, 0.1));
      for (var distance = 320.0; distance >= 5; distance -= 15) {
        await a.moveTo(Offset(190 - distance, 350));
        await b.moveTo(Offset(190 + distance, 350));
        await tester.pump();
      }
      expect(dayWidth(), closeTo((390 - 34) / 4, 0.1));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
