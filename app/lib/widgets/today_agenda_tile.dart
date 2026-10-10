import 'package:flutter/material.dart';

import '../models.dart';
import '../ddl_postponement.dart';
import 'postpone_ddl.dart';
import 'task_completion_control.dart';

/// The day overview is for scanning; full titles and notes stay in the editor.
class TodayAgendaTile extends StatelessWidget {
  const TodayAgendaTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onToggle,
  });

  final TimelineItem item;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) => _TodayOverviewCard(
    title: item.title,
    metadata: '${item.startLabel}–${item.endLabel}',
    tag: item.type == 'class' ? '课程' : null,
    done: item.done,
    onOpen: onOpen,
    onToggle: item.type == 'class' ? null : onToggle,
  );
}

/// Unscheduled deadlines share the same dimensions as the day's arrangements.
class TodayDeadlineTile extends StatelessWidget {
  const TodayDeadlineTile({
    super.key,
    required this.task,
    required this.now,
    required this.listColor,
    required this.onOpen,
    required this.onToggle,
  });

  final InboxTask task;
  final DateTime Function() now;
  final Color listColor;
  final VoidCallback onOpen, onToggle;

  @override
  Widget build(BuildContext context) {
    final clock = now();
    return _TodayOverviewCard(
      title: task.title,
      metadata: dueLabel(task.dueDate, task.dueTime, now: clock),
      done: task.done,
      onOpen: onOpen,
      onToggle: onToggle,
      completionColor: prioColor(task.priority, fallback: listColor),
      overdue: dueOverdue(task.dueDate, task.dueTime, now: clock),
      extraAction: canPostponeDdl(task, now: clock)
          ? PostponeDdlButton(task: task, now: now)
          : null,
    );
  }
}

class _TodayOverviewCard extends StatelessWidget {
  const _TodayOverviewCard({
    required this.title,
    required this.metadata,
    required this.done,
    required this.onOpen,
    required this.onToggle,
    this.tag,
    this.completionColor,
    this.overdue = false,
    this.extraAction,
  });

  final String title, metadata;
  final String? tag;
  final bool done;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;
  final Color? completionColor;
  final bool overdue;
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const titleStyle = TextStyle(
      fontSize: 15,
      height: 1.4,
      fontWeight: FontWeight.w600,
    );
    // Reserve two readable title lines for both short and long entries. Scale
    // the space with the user's text setting instead of fixing the card height.
    final titleHeight = MediaQuery.textScalerOf(context).scale(15) * 1.4 * 2;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            metadata,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              fontWeight: overdue
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: overdue
                                  ? const Color(0xFFE05858)
                                  : done
                                  ? scheme.onSurfaceVariant
                                  : scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: titleHeight,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle.copyWith(
                            decoration: done
                                ? TextDecoration.lineThrough
                                : null,
                            color: done
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (onToggle != null) ...[
                const SizedBox(width: 8),
                if (extraAction != null) extraAction!,
                TaskCompletionControl(
                  title: title,
                  done: done,
                  onToggle: onToggle!,
                  color:
                      completionColor ??
                      (done ? scheme.primary : scheme.outline),
                ),
              ] else if (tag != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: '课程',
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.school_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                      semanticLabel: '课程',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
