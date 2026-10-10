import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api.dart';
import '../models.dart';
import 'task_planning_controls.dart';
import 'postpone_ddl.dart';
import '../ddl_postponement.dart';

/// 任务编辑器：标题 + 归属(其他/今天/某清单) + 优先级 + 截止日期/时刻 + 备注 + 保存/删除。
/// list 只表示「新增时的预设归属清单」(可为空)，真实归属看 listId。
/// lockDueToday 用于「今天」入口：截止日期被钉在今天，不给改。
/// 自包含完成 addInbox/updateInbox/deleteInbox，改动后返回 true 供调用方刷新。
Future<bool> showTaskEditor(
  BuildContext context, {
  ListInfo? list,
  InboxTask? task,
  String? initialDueDate, // 新增时预设截止日(如 DDL 板块选中某天)，yyyy-MM-dd
  bool lockDueToday = false,
  List<ListInfo>? lists, // 调用方已有的清单，省一次请求
}) async {
  final isNew = task == null;
  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  // 锁在今天只对「新增」生效：编辑一条过期任务时如果强行改成今天，
  // 会变成用户没同意的改期。编辑态一律按原样打开。
  var locked = lockDueToday && isNew;
  final known = lists ?? await _fetchLists();
  if (!context.mounted) return false; // 拉清单是异步的，期间页面可能已经被弹走

  final titleCtrl = TextEditingController(text: task?.title ?? '');
  final notesCtrl = TextEditingController(text: task?.notes ?? '');
  final estimateCtrl = TextEditingController(text: task?.estimateMinutes?.toString() ?? '');
  var estimateUnit = 1;
  final fallback = _hex(list?.color ?? '') ?? const Color(0xFF5C8DEF);
  var prio = task?.priority.clamp(0, 3) ?? 0;
  var listId = task?.listId ?? list?.id;
  var dueDate = locked ? today : (task?.dueDate ?? initialDueDate);
  var dueTime = task?.dueTime;
  var saving = false;
  Map<String,dynamic>? schedule = task?.schedule;
  DateTime? reminder = task?.reminderAt == null ? null : DateTime.parse(task!.reminderAt!).toLocal();
  var reminderEdited = false;
  ModalRoute<dynamic>? editorRoute;

  /// 当前归属的清单对象：只在确实是某条清单时才返回，找不到就当作无归属。
  ListInfo? owner() {
    for (final l in known) {
      if (l.id == listId) return l;
    }
    return list?.id == listId ? list : null;
  }

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        editorRoute ??= ModalRoute.of(ctx);
        Future<void> save() async {
          final title = titleCtrl.text.trim();
          if (title.isEmpty) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('填个标题吧')));
            return;
          }
          final rawEstimate = estimateCtrl.text.trim();
          final value = rawEstimate.isEmpty ? null : double.tryParse(rawEstimate);
          final minutes = value == null ? null : value * estimateUnit;
          if (rawEstimate.isNotEmpty && (minutes == null || !minutes.isFinite || minutes < 1 || minutes > 10080 || (minutes - minutes.round()).abs() > 0.000001)) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('预计用时请填写有效的分钟或小时，总时长不超过7天')));
            return;
          }
          setState(() => saving = true);
          try {
            var effectiveReminder = reminder;
            if (!reminderEdited && reminder != null && task?.dueDate != null && dueDate != null) {
              final oldDue = DateTime.parse(task!.dueDate!).add(Duration(minutes: task.dueTime ?? 540));
              final newDue = DateTime.parse(dueDate!).add(Duration(minutes: dueTime ?? 540));
              effectiveReminder = reminder!.add(newDue.difference(oldDue));
            }
            await Api.instance.savePlannedTask(task?.id, {
              'title': title, 'priority': prio, 'notes': notesCtrl.text.trim(),
              'list_id': listId,
              'due_date': dueDate, 'due_time': dueDate == null ? null : dueTime,
              'reminder_at': effectiveReminder?.toUtc().toIso8601String(), 'schedule': schedule,
              'estimate_minutes': minutes?.round(),
            });
            if (ctx.mounted) Navigator.pop(ctx, true);
          } on ApiException catch (e) {
            if (ctx.mounted) {
              setState(() => saving = false);
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message)));
            }
          }
        }

        Future<void> del() async {
          final t = task;
          if (t == null || t.id == null) return;
          setState(() => saving = true);
          try {
            await Api.instance.deleteInbox(t.id!);
            if (ctx.mounted) Navigator.pop(ctx, true);
          } on ApiException catch (e) {
            if (ctx.mounted) {
              setState(() => saving = false);
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message)));
            }
          }
        }

        Future<void> pickDueDate() async {
          final now = DateTime.now();
          final init = DateTime.tryParse(dueDate ?? '') ?? now;
          final d = await showDatePicker(
            context: ctx,
            initialDate: init,
            firstDate: DateTime(now.year - 2),
            lastDate: DateTime(now.year + 10),
          );
          if (d == null) return;
          setState(() => dueDate = DateFormat('yyyy-MM-dd').format(d));
        }

        Future<void> pickDueTime() async {
          final cur = dueTime ?? 540; // 默认 09:00
          final t = await showTimePicker(
            context: ctx,
            initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
          );
          if (t == null) return;
          setState(() => dueTime = t.hour * 60 + t.minute);
        }

        void quickSet(int days) {
          final d = DateTime.now().add(Duration(days: days));
          setState(() {
            dueDate = DateFormat('yyyy-MM-dd').format(d);
            dueTime = null; // 快捷设置只到日期，时刻另点
          });
        }

        /// 归属选择：今天(锁日期) / 其他(不归任何清单) / 收集箱 / 你的清单。
        Future<void> pickList() async {
          final picked = await showModalBottomSheet<String>(
            context: ctx,
            backgroundColor: Theme.of(ctx).colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (sheetCtx) {
              final scheme = Theme.of(sheetCtx).colorScheme;
              Widget tile({required String emoji, required String name, String? sub,
                           required bool selected, required String value}) =>
                  ListTile(
                    leading: Text(emoji, style: const TextStyle(fontSize: 20)),
                    title: Text(name, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
                    subtitle: sub == null ? null : Text(sub, style: TextStyle(fontSize: 12, color: scheme.outline)),
                    trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
                    onTap: () => Navigator.pop(sheetCtx, value),
                  );
              return SafeArea(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                      child: Text('添加到清单', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.outline)),
                    ),
                    tile(
                      emoji: '📅', name: '今天',
                      sub: '截止日期锁在今天',
                      selected: locked, value: '_today',
                    ),
                    tile(
                      emoji: '🗂️', name: '其他',
                      sub: '不属于任何清单，日期随便挑',
                      selected: !locked && listId == null, value: '_none',
                    ),
                    const Divider(height: 1),
                    // 已完成/回收站是自动归集的，人为往里放任务只会自相矛盾，所以不给选。
                    for (final l in known.where((l) => !l.isDerived))
                      tile(
                        emoji: l.emoji.isNotEmpty ? l.emoji : '📋',
                        name: l.name,
                        sub: l.system == 'inbox' ? '临时放突然冒出来的想法' : null,
                        selected: !locked && listId == l.id,
                        value: 'list:${l.id}',
                      ),
                  ],
                ),
              );
            },
          );
          if (picked == null) return;
          setState(() {
            if (picked == '_today') {
              locked = true;
              listId = null;
              dueDate = today;
            } else if (picked == '_none') {
              locked = false;
              listId = null;
            } else {
              locked = false;
              listId = int.tryParse(picked.substring(5));
            }
          });
        }

        final labelStyle = TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.outline);
        String tfmt(int? m) {
          if (m == null) return '设时刻';
          final h = (m ~/ 60).toString().padLeft(2, '0');
          final mm = (m % 60).toString().padLeft(2, '0');
          return '$h:$mm';
        }

        final own = owner();
        final draft = task == null ? null : InboxTask(
          id: task.id, title: titleCtrl.text, done: task.done,
          dueDate: dueDate, dueTime: dueTime, schedule: schedule,
          reminderAt: reminder?.toUtc().toIso8601String(),
        );

        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (draft != null && canPostponeDdl(draft))
                    TextButton.icon(
                      icon: const Icon(Icons.update),
                      label: const Text('顺延 DDL'),
                      onPressed: saving ? null : () async {
                        await showPostponeDdl(ctx, draft, onSave: (patch) async {
                          setState(() {
                            dueDate = patch['due_date'] as String;
                            dueTime = patch['due_time'] as int?;
                            reminder = patch['reminder_at'] == null ? null
                                : DateTime.parse(patch['reminder_at'] as String).toLocal();
                            reminderEdited = true;
                          });
                        });
                      },
                    ),
                  Row(
                    children: [
                      // 归属是可点的：点开换清单，不再是一个查不到出处的死标签
                      Flexible(
                        child: InkWell(
                          onTap: saving ? null : pickList,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  locked ? '📅'
                                      : own != null && own.emoji.isNotEmpty ? own.emoji
                                      : own != null ? '📋' : '🗂️',
                                  style: const TextStyle(fontSize: 20),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    locked ? '今天' : own?.name ?? '其他',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                Icon(Icons.expand_more, size: 18, color: Theme.of(ctx).colorScheme.outline),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(Icons.flag, color: prioColor(prio, fallback: fallback)),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        visualDensity: VisualDensity.compact,
                        onPressed: saving ? null : () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: titleCtrl,
                    autofocus: isNew,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(hintText: '做什么?', border: InputBorder.none),
                    onSubmitted: (_) => save(),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (final (label, val) in const [('低', 1), ('中', 2), ('高', 3)]) ...[
                        // 点当前选中项=取消优先级(回到无)，顶替原"无"胶囊
                        _prioChip(label, prio, val, fallback, () => setState(() => prio = prio == val ? 0 : val), ctx),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('截止日期', style: labelStyle),
                  const SizedBox(height: 8),
                  if (locked)
                    // 从「今天」进来的任务：日期就是它存在的理由，不给改。
                    Row(
                      children: [
                        Chip(
                          avatar: const Icon(Icons.lock_outline, size: 15),
                          label: const Text('今天'),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.10),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('从「今天」添加的任务锁在今天；想改日期就点上方归属换一个',
                              style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.outline)),
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        _quickChip('今天', () => quickSet(0), ctx),
                        const SizedBox(width: 8),
                        _quickChip('明天', () => quickSet(1), ctx),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: saving ? null : pickDueDate,
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(dueDate == null ? '选日期' : dueLabel(dueDate, null)),
                        ),
                        if (dueDate != null) ...[
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: saving ? null : () => setState(() {
                                  dueDate = null;
                                  dueTime = null;
                                }),
                          ),
                        ],
                      ],
                    ),
                  if (dueDate != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('时刻', style: labelStyle),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: saving ? null : pickDueTime,
                          child: Text(tfmt(dueTime)),
                        ),
                        if (dueTime != null) ...[
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: saving ? null : () => setState(() => dueTime = null),
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 3,
                    style: const TextStyle(),
                    decoration: InputDecoration(
                      hintText: '备注',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Theme.of(ctx).colorScheme.outlineVariant),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: TextField(
                      controller: estimateCtrl,
                      enabled: !saving,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: '预计用时（可选）', hintText: '留空表示还不确定', border: OutlineInputBorder()),
                    )),
                    const SizedBox(width: 12),
                    DropdownButton<int>(value: estimateUnit, items: const [
                      DropdownMenuItem(value: 1, child: Text('分钟')),
                      DropdownMenuItem(value: 60, child: Text('小时')),
                    ], onChanged: saving ? null : (value) {
                      if (value == null) return;
                      final current = double.tryParse(estimateCtrl.text);
                      if (current != null) {
                        final next = current * estimateUnit / value;
                        estimateCtrl.text = next == next.roundToDouble() ? next.toInt().toString() : next.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
                      }
                      setState(() => estimateUnit = value);
                    }),
                  ]),
                  TaskPlanningControls(schedule: schedule, reminder: reminder,
                    dueDate: dueDate, dueTime: dueTime, busy: saving,
                    onSchedule: (v) => setState(() => schedule = v),
                    onReminder: (v) => setState(() { reminder = v; reminderEdited = true; })),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (!isNew)
                        TextButton.icon(
                          onPressed: saving ? null : del,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除'),
                          style: TextButton.styleFrom(foregroundColor: const Color(0xFFE05858)),
                        ),
                      if (isNew) const Spacer(),
                      if (!isNew) const Spacer(),
                      FilledButton(
                        onPressed: saving ? null : save,
                        style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
                        child: Text(isNew ? '添加' : '保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  // Navigator.pop resolves the result before the sheet's exit animation ends.
  // Its text fields must keep their controllers until the route is disposed.
  await editorRoute?.completed;
  titleCtrl.dispose();
  notesCtrl.dispose();
  estimateCtrl.dispose();
  return result ?? false;
}

/// 拉清单给归属选择器用。失败不拦人：退化成只有「今天 / 其他」两个选项，
/// 总比打不开编辑器强(反正在线时上一页已经拉过一次了)。
Future<List<ListInfo>> _fetchLists() async {
  try {
    return await Api.instance.lists();
  } catch (_) {
    return const [];
  }
}

Widget _quickChip(String label, VoidCallback onTap, BuildContext ctx) {
  final scheme = Theme.of(ctx).colorScheme;
  return OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      side: BorderSide(color: scheme.outlineVariant),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(label, style: TextStyle(fontSize: 13, color: scheme.outline)),
  );
}

Widget _prioChip(String label, int cur, int val, Color fallback, VoidCallback onTap, BuildContext ctx) {
  final color = prioColor(val, fallback: fallback);
  final selected = cur == val;
  final scheme = Theme.of(ctx).colorScheme;
  return GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? color : scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? color : scheme.outline,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
  );
}

Color? _hex(String hex) {
  if (hex.length < 7) return null;
  final v = int.tryParse('FF${hex.substring(1)}', radix: 16);
  return v == null ? null : Color(v);
}
