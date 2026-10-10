import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/widgets/course_details_sheet.dart';

void main() {
  const course = TimelineItem(
    type: 'class',
    title: '市场营销学',
    startMin: 8 * 60,
    endMin: 9 * 60 + 40,
    color: '#4A90D9',
    room: '商学院 204',
    teacher: '王老师',
    weekNum: 3,
  );

  Future<void> openCourse(WidgetTester tester, TimelineItem item) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCourseDetails(context, item),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('课程详情显示权威地点、教师、周次和时间', (tester) async {
    await openCourse(tester, course);

    expect(find.text('课程详情'), findsOneWidget);
    expect(find.text('市场营销学'), findsOneWidget);
    expect(find.text('地点'), findsOneWidget);
    expect(find.text('商学院 204'), findsOneWidget);
    expect(find.text('教师'), findsOneWidget);
    expect(find.text('王老师'), findsOneWidget);
    expect(find.text('第 3 周'), findsOneWidget);
    expect(find.text('08:00–09:40'), findsOneWidget);
  });

  testWidgets('课程没有地点时不显示地点行', (tester) async {
    await openCourse(
      tester,
      const TimelineItem(
        type: 'class',
        title: '体育',
        startMin: 600,
        endMin: 660,
        color: '#4A90D9',
      ),
    );

    expect(find.text('体育'), findsOneWidget);
    expect(find.text('地点'), findsNothing);
  });
}
