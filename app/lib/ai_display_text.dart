String aiOperationLabel(String operation) => switch (operation) {
  'schedule_task' => '安排任务',
  'unschedule_task' => '取消原安排',
  'create_block' => '新建时间段',
  'create_task' => '新建任务',
  _ => '调整安排',
};

String aiDraftStatusLabel(String status) => switch (status) {
  'pending' => '等待确认',
  'applied' => '已应用',
  'discarded' => '已被新方案替代',
  'expired' => '已过期',
  _ => '状态待确认',
};

String aiWarningText(String code) => switch (code) {
  'COURSE_CONFLICT' => '与课程时间冲突',
  'TIME_OVERLAP' => '与已有安排重叠',
  'DRAFT_STALE' => '任务已经发生变化，请重新生成安排',
  _ => '这份安排需要再确认一下',
};

final RegExp _internalAiTerm = RegExp(
  r'\b(?:schedule_task|unschedule_task|create_block|create_task|DRAFT_[A-Z_]+|taskId|JSON Schema)\b',
  caseSensitive: false,
);

String aiSafeText(Object? value, {String fallback = '我需要重新整理一下这份安排，请再试一次。'}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || _internalAiTerm.hasMatch(text)) return fallback;
  return text;
}

String aiErrorText(String? code, Object? message) => switch (code) {
  'AI_BUSY' => '已有一份安排正在生成，请等它完成后再继续',
  'AI_BUDGET_EXHAUSTED' => '今天的服务调用预算已用完，请明天再试，或使用自己的模型服务',
  'AI_RETRY_LATER' => '刚才的请求没能完成，请稍等半分钟再试',
  'AI_RATE_LIMITED' => '请求有些频繁，请稍等一会儿再继续',
  'AI_CONTEXT_CHANGED' => '生成期间你的任务或日程发生了变化，这份结果没有应用。请按最新日程重新生成。',
  'AI_SYNC_REQUIRED' => '还有本机修改未同步，请先完成同步，再让 AI 安排或应用方案。',
  'DRAFT_STALE' => '任务已经发生变化，请重新生成安排',
  'DRAFT_EXPIRED' => '这份安排已经过期，请重新生成一份',
  'DRAFT_BLOCKED' => '这份安排和现有日程有冲突，请调整后再试',
  'AI_SESSION_EXPIRED' => '这次对话已保存到历史记录，你可以重新生成一份安排',
  'AI_PROVIDER_UNAVAILABLE' => 'AI 服务暂时有点忙，请稍后再试',
  'AI_PROPOSAL_INVALID' => '这次没能整理出可用的安排，你的日程没有改动。可以稍后再试。',
  'AI_PLAN_CONFLICT' => aiSafeText(message, fallback: '时间安排有冲突，请调整要求后再试'),
  'AI_REQUIREMENTS_INVALID' => aiSafeText(message, fallback: '请检查并确认本次要求'),
  'AI_UNDO_STALE' => '相关安排已被修改，无法直接撤销。请按最新日程重新规划。',
  _ => aiSafeText(message, fallback: '暂时没能完成这次操作，请稍后再试'),
};
