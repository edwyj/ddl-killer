import 'package:intl/intl.dart';

import 'models.dart';

bool canPostponeDdl(InboxTask task, {DateTime? now}) =>
    task.id != null &&
    !task.done &&
    dueOverdue(task.dueDate, task.dueTime, now: now);

/// Absolute dates make offline retries idempotent. Never include the schedule:
/// postponing a deadline must not move the task's calendar appointment.
Map<String, dynamic> postponedDdlPatch(
  InboxTask task,
  DateTime target, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  if (!canPostponeDdl(task, now: clock)) throw ArgumentError('只能顺延过期且未完成的任务');
  final day = DateTime(target.year, target.month, target.day);
  final today = DateTime(clock.year, clock.month, clock.day);
  final date = DateFormat('yyyy-MM-dd').format(day);
  if (day.isBefore(today) ||
      dueOverdue(date, task.dueTime, now: clock) ||
      (day == today &&
          task.dueTime != null &&
          task.dueTime! <= clock.hour * 60 + clock.minute)) {
    throw ArgumentError('请选择尚未过期的截止日期');
  }
  final oldDay = DateTime.parse(task.dueDate!);
  final oldDue = DateTime(
    oldDay.year,
    oldDay.month,
    oldDay.day,
    0,
    task.dueTime ?? 540,
  );
  final newDue = DateTime(day.year, day.month, day.day, 0, task.dueTime ?? 540);
  final oldReminder = DateTime.tryParse(task.reminderAt ?? '');
  final reminder = oldReminder?.add(newDue.difference(oldDue));
  return {
    'due_date': date,
    'due_time': task.dueTime,
    'reminder_at': reminder != null && reminder.isAfter(clock)
        ? reminder.toUtc().toIso8601String()
        : null,
  };
}
