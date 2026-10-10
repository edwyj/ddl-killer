import 'package:flutter/material.dart';

import '../models/ai_planner.dart';
import '../ai_display_text.dart';
import 'task_completion_control.dart';

class AiDraftPreview extends StatelessWidget {
  const AiDraftPreview({
    super.key,
    required this.result,
    this.selectedIds,
    this.onSelectionChanged,
  });

  final AiTurnResult result;
  final Set<String>? selectedIds;
  final void Function(String)? onSelectionChanged;

  static String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  String _after(AiDraftChange change) {
    if (change.operation == 'unschedule_task') return '取消安排';
    if (change.date == null || change.start == null || change.end == null) {
      if (change.operation == 'create_task') return '加入任务列表，暂不排期';
      return '更新安排';
    }
    final date = DateTime.tryParse(change.date!);
    final label = date == null ? change.date : '${date.month}月${date.day}日';
    return '$label  ${_time(change.start!)}–${_time(change.end!)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warnings = {
      ...result.warnings.map(aiSafeText),
      ...result.draft.warnings.map(
        (warning) =>
            aiSafeText(warning.message, fallback: aiWarningText(warning.code)),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 7),
            Text(
              result.draft.status == 'applied'
                  ? '已应用的安排'
                  : result.outcome == 'proposal'
                  ? '待你确认的安排'
                  : result.outcome == 'clarification'
                  ? '先补充一点信息'
                  : result.warnings.isEmpty
                  ? '保持现有安排'
                  : '暂不调整安排',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (result.draft.changes.isNotEmpty)
              Text(
                '${result.draft.changes.length} 项调整',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          aiSafeText(result.summary),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 10),
        for (final change in result.draft.changes)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (change.id != null && onSelectionChanged != null)
                    TaskCompletionControl(
                      key: ValueKey('ai-select-${change.id}'),
                      done: selectedIds?.contains(change.id) == true,
                      color: scheme.primary,
                      title: change.title,
                      actionLabel:
                          '${selectedIds?.contains(change.id) == true ? '取消选择' : '选择'}「${change.title}」',
                      onToggle: () => onSelectionChanged!(change.id!),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            aiSafeText(
                              change.title,
                              fallback: aiOperationLabel(change.operation),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          if (change.reason.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              aiSafeText(change.reason),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          if (change.operation == 'create_task') ...[
                            Text(
                              [
                                '确认后新建任务',
                                if (change.estimateMinutes != null)
                                  '预计 ${change.estimateMinutes} 分钟',
                                if (change.dueDate != null)
                                  '截止 ${change.dueDate}${change.dueTime == null ? '' : ' ${_time(change.dueTime!)}'}',
                              ].join(' · '),
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            '${aiSafeText(change.before ?? '未安排')} → ${_after(change)}',
                            style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                          if (change.title.length > 65 ||
                              change.reason.length > 80)
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              title: const Text(
                                '查看详情',
                                style: TextStyle(fontSize: 12),
                              ),
                              children: [
                                SelectableText(aiSafeText(change.title)),
                                if (change.reason.isNotEmpty)
                                  Text(aiSafeText(change.reason)),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final warning in warnings)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: scheme.tertiary,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(warning)),
              ],
            ),
          ),
        for (final question in result.questions)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(aiSafeText(question)),
          ),
        // AI 排期属自动化决策场景：结果只是建议，写入前由用户自己确认。
        // 放在列表末尾、紧邻"应用安排"按钮，正是做决定前会扫到的地方。
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '以上安排由 AI 生成，仅供参考，应用前建议自行核对。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
