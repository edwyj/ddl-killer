import 'package:flutter/material.dart';

import '../models.dart';

Future<void> showCourseDetails(BuildContext context, TimelineItem item) {
  assert(item.type == 'class');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _CourseDetails(item: item),
  );
}

class _CourseDetails extends StatelessWidget {
  const _CourseDetails({required this.item});

  final TimelineItem item;

  @override
  Widget build(BuildContext context) {
    final room = item.room?.trim();
    final teacher = item.teacher?.trim();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('课程详情', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            Text(
              item.title,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            _DetailRow(
              icon: Icons.schedule_outlined,
              label: '时间',
              value: '${item.startLabel}–${item.endLabel}',
            ),
            if (item.weekNum != null)
              _DetailRow(
                icon: Icons.calendar_today_outlined,
                label: '周次',
                value: '第 ${item.weekNum} 周',
              ),
            if (room != null && room.isNotEmpty)
              _DetailRow(
                icon: Icons.location_on_outlined,
                label: '地点',
                value: room,
              ),
            if (teacher != null && teacher.isNotEmpty)
              _DetailRow(
                icon: Icons.person_outline,
                label: '教师',
                value: teacher,
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text(label, style: TextStyle(color: scheme.outline)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
