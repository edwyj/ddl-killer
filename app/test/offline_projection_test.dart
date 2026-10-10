import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/offline_projection.dart';

void main() {
  test(
    'offline course projection keeps imported room as authoritative data',
    () {
      final items = dayItems({
        'schedule': {
          'semester_start': '2026-08-31',
          'period_to_block': {'1': '1'},
          'period_times': {
            '1': ['08:00', '09:40'],
          },
          'courses': [
            {
              'course_id': 'marketing',
              'name': '市场营销学',
              'teacher': '王老师',
              'slots': [
                {
                  'weekday': 1,
                  'periods': [1],
                  'weeks': [1],
                  'room': '商学院 204',
                },
              ],
            },
          ],
        },
        'blocks': <Map<String, dynamic>>[],
      }, '2026-08-31');

      expect(items.single['room'], '商学院 204');
      expect(items.single['teacher'], '王老师');
    },
  );
}
