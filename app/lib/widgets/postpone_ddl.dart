import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../ddl_postponement.dart';
import '../models.dart';

/// The dialog owns saving, so a failed request retains the chosen date for retry.
Future<bool> showPostponeDdl(
  BuildContext context,
  InboxTask task, {
  Future<void> Function(Map<String, dynamic>)? onSave,
  DateTime Function()? now,
}) async {
  if (!canPostponeDdl(task, now: now?.call())) return false;
  return await showDialog<bool>(
        context: context,
        builder: (_) => _PostponeDialog(task: task, onSave: onSave, now: now),
      ) ??
      false;
}

class PostponeDdlButton extends StatelessWidget {
  const PostponeDdlButton({super.key, required this.task, this.now});
  final InboxTask task;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => !canPostponeDdl(task, now: now?.call())
      ? const SizedBox.shrink()
      : TextButton(
          onPressed: () => showPostponeDdl(context, task, now: now),
          child: const Text('顺延'),
        );
}

class _PostponeDialog extends StatefulWidget {
  const _PostponeDialog({required this.task, this.onSave, this.now});
  final InboxTask task;
  final DateTime Function()? now;
  final Future<void> Function(Map<String, dynamic>)? onSave;
  @override
  State<_PostponeDialog> createState() => _PostponeDialogState();
}

class _PostponeDialogState extends State<_PostponeDialog> {
  final _days = TextEditingController(text: '1');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now?.call() ?? DateTime.now();
    final count = int.tryParse(_days.text);
    final validDays = count != null && count >= 0 && count <= 3650;
    final date = validDays
        ? DateTime(now.year, now.month, now.day + count)
        : null;
    Map<String, dynamic>? patch;
    String? validation;
    if (date == null) {
      validation = '请输入 0 到 3650 的整数天数';
    } else {
      try {
        patch = postponedDdlPatch(widget.task, date, now: now);
      } on ArgumentError catch (e) {
        validation = e.message.toString();
      }
    }
    final reminder = patch?['reminder_at'] as String?;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('顺延 DDL'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.task.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                '原截止：${dueLabel(widget.task.dueDate, widget.task.dueTime, now: now)}',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final option in [(0, '今天'), (1, '明天'), (7, '一周后')])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: count == option.$1,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                              _days.text = '${option.$1}';
                              _error = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _days,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '从今天起顺延',
                  suffixText: '天',
                  helperText: '0 表示今天，1 表示明天',
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: const Text('指定日期'),
                onPressed: _saving
                    ? null
                    : () async {
                        final today = DateTime(now.year, now.month, now.day);
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: date ?? today,
                          firstDate: today,
                          lastDate: DateTime(
                            now.year,
                            now.month,
                            now.day + 3650,
                          ),
                        );
                        if (picked != null && mounted) {
                          setState(() {
                            _days.text =
                                '${DateTime.utc(picked.year, picked.month, picked.day).difference(DateTime.utc(now.year, now.month, now.day)).inDays}';
                            _error = null;
                          });
                        }
                      },
              ),
              if (date != null)
                Text(
                  '新截止：${dueLabel(DateFormat('yyyy-MM-dd').format(date), widget.task.dueTime, now: now)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              if (widget.task.schedule != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('日历排期保持不变。'),
                ),
              if (widget.onSave != null) const Text('应用后请在任务编辑中保存。'),
              if (widget.task.reminderAt != null && patch != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    reminder == null
                        ? '原提醒顺延后仍已过期，本次将清除提醒；可在任务编辑中重新设置。'
                        : '提醒同步到 ${DateFormat('M月d日 HH:mm').format(DateTime.parse(reminder).toLocal())}',
                  ),
                ),
              if (validation != null || _error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    validation ?? _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving || patch == null
                ? null
                : () async {
                    setState(() {
                      _saving = true;
                      _error = null;
                    });
                    try {
                      // Revalidate at submission: the clock may have crossed the deadline.
                      final body = postponedDdlPatch(
                        widget.task,
                        date!,
                        now: widget.now?.call(),
                      );
                      if (widget.onSave != null) {
                        await widget.onSave!(body);
                      } else {
                        await Api.instance.savePlannedTask(
                          widget.task.id!,
                          body,
                        );
                      }
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          _saving = false;
                          _error = e is ApiException
                              ? e.message
                              : e is ArgumentError
                              ? e.message.toString()
                              : '顺延失败，请重试';
                        });
                      }
                    }
                  },
            child: Text(_saving ? '保存中…' : '确认顺延'),
          ),
        ],
      ),
    );
  }
}
