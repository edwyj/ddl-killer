import 'dart:ui' show Color;
import 'package:intl/intl.dart';

/// DDL 窗口(天)：距今天 ≤ 该天数的截止任务算"DDL"进 DDL 板块；更远或无日期则算"清单项"。
/// 嫌紧/嫌松只改这一个数。
const int ddlLookaheadDays = 30;

/// 优先级颜色:0无(清单色) 1低(蓝) 2中(橙) 3高(红)。清单页与任务编辑器共用。
Color prioColor(int prio, {required Color fallback}) {
  switch (prio) {
    case 3:
      return const Color(0xFFE05858);
    case 2:
      return const Color(0xFFE8A33D);
    case 1:
      return const Color(0xFF5C8DEF);
    default:
      return fallback;
  }
}

/// 截止日期/时刻的展示文案。如 今天 / 明天 / 昨天 / 2026年9月6日；有时刻则追加 " 10:00"。
String dueLabel(String? dueDate, int? dueTime, {DateTime? now}) {
  final base = now ?? DateTime.now();
  if (dueDate == null || dueDate.isEmpty) return '';
  final d = DateTime.tryParse(dueDate);
  if (d == null) return '';
  final today = DateTime(base.year, base.month, base.day);
  final dueDay = DateTime(d.year, d.month, d.day);
  final diff = dueDay.difference(today).inDays;
  final String datePart;
  if (diff == 0) {
    datePart = '今天';
  } else if (diff == 1) {
    datePart = '明天';
  } else if (diff == -1) {
    datePart = '昨天';
  } else if (d.year == base.year) {
    datePart = '${d.month}月${d.day}日';
  } else {
    datePart = '${d.year}年${d.month}月${d.day}日';
  }
  if (dueTime == null) return datePart;
  final h = (dueTime ~/ 60).toString().padLeft(2, '0');
  final m = (dueTime % 60).toString().padLeft(2, '0');
  return '$datePart $h:$m';
}

/// 是否已过期:日期早于今天，或今天但时刻已过。
bool dueOverdue(String? dueDate, int? dueTime, {DateTime? now}) {
  final base = now ?? DateTime.now();
  if (dueDate == null || dueDate.isEmpty) return false;
  final d = DateTime.tryParse(dueDate);
  if (d == null) return false;
  final today = DateTime(base.year, base.month, base.day);
  final dueDay = DateTime(d.year, d.month, d.day);
  if (dueDay.isBefore(today)) return true;
  if (dueDay == today && dueTime != null) {
    final nowMin = base.hour * 60 + base.minute;
    return dueTime < nowMin;
  }
  return false;
}

/// DDL 专属文案：已过期N天 / 今天 HH:mm / 今天 / 还剩N天。无日期返回 ''。
String ddlCountdown(String? dueDate, int? dueTime, {DateTime? now}) {
  if (dueDate == null || dueDate.isEmpty) return '';
  final d = DateTime.tryParse(dueDate);
  if (d == null) return '';
  final base = now ?? DateTime.now();
  final today = DateTime(base.year, base.month, base.day);
  final dueDay = DateTime(d.year, d.month, d.day);
  final diff = dueDay.difference(today).inDays;
  if (diff < 0) return '已过期${-diff}天';
  if (diff == 0) {
    if (dueTime == null) return '今天';
    final h = (dueTime ~/ 60).toString().padLeft(2, '0');
    final m = (dueTime % 60).toString().padLeft(2, '0');
    return '今天 $h:$m';
  }
  return '还剩$diff天';
}

/// 中文星期：1=周一 … 7=周日。
String cnWeekday(DateTime d) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return names[(d.weekday - 1) % 7];
}

/// 把标题里**结尾的括号描述**拆成 (标题, 备注)。支持半角()/全角（）。无尾括号则 (原样, null)。
/// e.g. "午饭+机动(16点生伦下课到19点武术前)" -> ("午饭+机动", "16点生伦下课到19点武术前")
(String, String?) splitTitleNote(String title) {
  final t = title.trim();
  final m = RegExp(r'^(.*?)\s*[\(（]([^\(\)（）]*)[\)）]\s*$').firstMatch(t);
  if (m != null) {
    final head = m.group(1)!.trim();
    final note = m.group(2)!.trim();
    return (head.isEmpty ? t : head, note.isEmpty ? null : note);
  }
  return (t, null);
}

/// 时间轴条目:课程(class)或任务(task)
class TimelineItem {
  final String type; // class | task
  final int? id; // 任务块的数据库 id(课程为 null)
  final String title;
  final int startMin; // 0-1439
  final int endMin;
  final String color; // 十六进制,如 #4a90d9
  final String? room;
  final String? teacher;
  final String? note; // 备注(用户可编辑；旧标题里的尾括号在显示/编辑时也当成备注)
  final bool done;
  final int? weekNum;
  final int? block; // 大节号(课程用，课表网格分行)

  const TimelineItem({
    required this.type,
    this.id,
    required this.title,
    required this.startMin,
    required this.endMin,
    required this.color,
    this.room,
    this.teacher,
    this.note,
    this.done = false,
    this.weekNum,
    this.block,
  });

  factory TimelineItem.fromJson(Map<String, dynamic> j) {
    final isClass = j['type'] == 'class';
    return TimelineItem(
      type: isClass ? 'class' : 'task',
      id: j['id'] as int?,
      title: (j['title'] ?? '').toString(),
      startMin: (j['start_min'] ?? 0) as int,
      endMin: (j['end_min'] ?? 0) as int,
      color: (j['color'] ?? (isClass ? '#4a90d9' : '#8e7cc3')).toString(),
      room: (j['room'] ?? '').toString().isEmpty ? null : j['room'].toString(),
      teacher: (j['teacher'] ?? '').toString().isEmpty ? null : j['teacher'].toString(),
      note: (j['notes'] ?? '').toString().trim().isEmpty ? null : (j['notes'] ?? '').toString(),
      done: (j['done'] ?? 0) == 1,
      weekNum: j['weekNum'] as int?,
      block: j['block'] as int?,
    );
  }

  String get startLabel => _fmt(startMin);
  String get endLabel => _fmt(endMin);

  static String _fmt(int min) {
    final h = (min ~/ 60).toString().padLeft(2, '0');
    final m = (min % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// 一天(周视图里的一列)
class WeekDay {
  final String date;
  final int weekday; // 1=周一
  final List<TimelineItem> items;

  const WeekDay({required this.date, required this.weekday, required this.items});
}

/// 清单
class ListInfo {
  final int? id;
  final String name;
  final String emoji;
  final String color;
  final int taskCount;

  /// 系统清单标记：'inbox'=收集箱(真容器) / 'done'=已完成 / 'trash'=回收站；null=普通清单。
  /// 已完成和回收站里的东西是自动归集的，任务不会真的带着它们的 id，
  /// 所以这两个只能当导航入口看，不能当成可以往里塞任务的清单。
  final String? system;

  const ListInfo({
    this.id,
    required this.name,
    this.emoji = '',
    this.color = '',
    this.taskCount = 0,
    this.system,
  });

  bool get isDerived => system == 'done' || system == 'trash';
  bool get isSystem => system != null;

  factory ListInfo.fromJson(Map<String, dynamic> j) => ListInfo(
        id: j['id'] as int?,
        name: (j['name'] ?? '').toString(),
        emoji: (j['emoji'] ?? '').toString(),
        color: (j['color'] ?? '').toString(),
        taskCount: (j['task_count'] ?? 0) as int,
        system: j['system'] as String?,
      );
}

/// 回收站里的一条：可能是任务，也可能是日历上直接建的独立时间块。
class TrashItem {
  final String kind; // 'task' | 'block'
  final int id;
  final String title;
  final String deletedAt; // ISO
  final String? dueDate;
  final String? date; // block 专用

  const TrashItem({
    required this.kind,
    required this.id,
    required this.title,
    this.deletedAt = '',
    this.dueDate,
    this.date,
  });

  factory TrashItem.fromJson(Map<String, dynamic> j) => TrashItem(
        kind: (j['kind'] ?? 'task').toString(),
        id: (j['id'] ?? 0) as int,
        title: (j['title'] ?? '').toString(),
        deletedAt: (j['deleted_at'] ?? '').toString(),
        dueDate: j['due_date']?.toString(),
        date: j['date']?.toString(),
      );

  /// 删除时刻的本地展示；解析不了就退回原文(总比空白强)。
  String get deletedLabel {
    final t = DateTime.tryParse(deletedAt)?.toLocal();
    if (t == null) return '';
    return DateFormat('M月d日 HH:mm').format(t);
  }
}

/// 收件箱任务
class InboxTask {
  final int? estimateMinutes;
  final String? reminderAt;
  final Map<String, dynamic>? schedule;
  final int? id;
  final String title;
  final int priority; // 0无 1低 2中 3高
  final bool done;
  final String notes;
  final String? dueDate; // 截止日期 YYYY-MM-DD(可空=无 ddl)
  final int? dueTime; // 截止时刻(当天分钟 0-1439，可空=只到日期)
  final int? listId; // 所属清单 id(可空=不属于任何清单，只有日期安排)
  final String? doneAt; // 完成时刻 ISO(可空=未完成)

  const InboxTask({
    this.estimateMinutes,
    this.reminderAt,
    this.schedule,
    this.id,
    required this.title,
    this.priority = 0,
    this.done = false,
    this.notes = '',
    this.dueDate,
    this.dueTime,
    this.listId,
    this.doneAt,
  });

  factory InboxTask.fromJson(Map<String, dynamic> j) => InboxTask(
        estimateMinutes: j['estimate_minutes'] as int?,
        reminderAt: j['reminder_at'] as String?,
        schedule: j['schedule'] == null ? null : Map<String,dynamic>.from(j['schedule'] as Map),
        id: j['id'] as int?,
        title: (j['title'] ?? '').toString(),
        priority: (j['priority'] ?? 0) as int,
        done: (j['done'] ?? 0) == 1,
        notes: (j['notes'] ?? '').toString(),
        dueDate: j['due_date']?.toString(),
        dueTime: j['due_time'] as int?,
        listId: j['list_id'] as int?,
        doneAt: j['done_at']?.toString(),
      );

  /// 完成时刻的本地展示(已完成列表用)。
  String get doneLabel {
    final t = DateTime.tryParse(doneAt ?? '')?.toLocal();
    return t == null ? '' : DateFormat('M月d日 HH:mm').format(t);
  }
}
