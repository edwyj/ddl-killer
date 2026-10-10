enum AiProviderMode { hosted, byok }

enum AiSessionStatus { active, applied, closed, expired }

extension AiSessionStatusX on AiSessionStatus {
  static AiSessionStatus fromWire(Object? value) => switch (value) {
    'active' => AiSessionStatus.active,
    'applied' => AiSessionStatus.applied,
    'closed' => AiSessionStatus.closed,
    _ => AiSessionStatus.expired,
  };
}

DateTime _dateTime(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return DateTime.parse(value.toString());
}

class AiQuota {
  const AiQuota({
    required this.limit,
    required this.used,
    required this.reserved,
    required this.remaining,
    required this.resetsAt,
    required this.hostedEnabled,
    required this.copy,
    this.entitlements = const [],
  });

  factory AiQuota.fromJson(Map value) => AiQuota(
    limit: value['limit'] as int,
    used: value['used'] as int,
    reserved: value['reserved'] as int,
    remaining: value['remaining'] as int,
    resetsAt: DateTime.parse(value['resetsAt'] as String),
    hostedEnabled: value['hostedEnabled'] as bool,
    copy: value['copy'] as String,
    entitlements: (value['entitlements'] as List? ?? const [])
        .map((entry) => AiEntitlement.fromJson(entry as Map))
        .toList(),
  );

  final int limit;
  final int used;
  final int reserved;
  final int remaining;
  final DateTime resetsAt;
  final bool hostedEnabled;
  final String copy;
  final List<AiEntitlement> entitlements;
}

class AiEntitlement {
  const AiEntitlement({
    required this.id,
    required this.name,
    required this.dailyLimit,
    required this.expiresAt,
  });
  factory AiEntitlement.fromJson(Map value) => AiEntitlement(
    id: value['id'] as String,
    name: value['name'] as String,
    dailyLimit: value['dailyLimit'] as int,
    expiresAt: DateTime.parse(value['expiresAt'] as String),
  );
  final String id;
  final String name;
  final int dailyLimit;
  final DateTime expiresAt;
}

class AiProviderSummary {
  const AiProviderSummary({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.keyMask,
    required this.updatedAt,
  });

  factory AiProviderSummary.fromJson(Map value) => AiProviderSummary(
    provider: value['provider'] as String,
    baseUrl: value['baseUrl'] as String,
    model: value['model'] as String,
    keyMask: value['keyMask'] as String,
    updatedAt: DateTime.parse(value['updatedAt'] as String),
  );

  final String provider;
  final String baseUrl;
  final String model;
  final String keyMask;
  final DateTime updatedAt;
}

class AiProviderInput {
  const AiProviderInput({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.key,
    this.password,
  });

  final String provider;
  final String baseUrl;
  final String model;
  final String key;
  final String? password;
}

class AiAssistantSettings {
  const AiAssistantSettings({
    required this.mode,
    required this.provider,
    required this.quota,
    this.featureEnabled = true,
  });

  final AiProviderMode mode;
  final AiProviderSummary? provider;
  final AiQuota quota;
  final bool featureEnabled;

  AiAssistantSettings copyWith({
    AiProviderMode? mode,
    AiProviderSummary? provider,
    bool clearProvider = false,
    AiQuota? quota,
    bool? featureEnabled,
  }) => AiAssistantSettings(
    mode: mode ?? this.mode,
    provider: clearProvider ? null : provider ?? this.provider,
    quota: quota ?? this.quota,
    featureEnabled: featureEnabled ?? this.featureEnabled,
  );
}

class AiPlanningWarning {
  const AiPlanningWarning({
    required this.code,
    required this.message,
    required this.blocking,
  });

  factory AiPlanningWarning.fromJson(Map value) => AiPlanningWarning(
    code: (value['code'] ?? 'WARNING').toString(),
    message: (value['message'] ?? '').toString(),
    blocking: value['severity'] == 'blocking',
  );

  final String code;
  final String message;
  final bool blocking;
}

class AiDraftChange {
  const AiDraftChange({
    this.id,
    this.taskId,
    required this.operation,
    required this.title,
    this.date,
    this.start,
    this.end,
    this.reason = '',
    this.before,
    this.estimateMinutes,
    this.dueDate,
    this.dueTime,
  });

  factory AiDraftChange.fromJson(Map value) => AiDraftChange(
    id: value['id']?.toString(),
    taskId: value['taskId'] as int?,
    operation: value['op'].toString(),
    title:
        (value['title'] ??
                (value['taskId'] == null ? '时间块' : '任务 #${value['taskId']}'))
            .toString(),
    date: value['date']?.toString(),
    start: value['start'] as int?,
    end: value['end'] as int?,
    reason: (value['reason'] ?? '').toString(),
    before: value['before']?.toString(),
    estimateMinutes: value['estimateMinutes'] as int?,
    dueDate: value['dueDate']?.toString(),
    dueTime: value['dueTime'] as int?,
  );

  final String operation;
  final String? id;
  final int? taskId;
  final String title;
  final String? date;
  final int? start;
  final int? end;
  final String reason;
  final String? before;
  final int? estimateMinutes;
  final String? dueDate;
  final int? dueTime;
}

class AiDraft {
  const AiDraft({
    required this.id,
    required this.status,
    required this.changes,
    required this.warnings,
  });

  factory AiDraft.fromJson(Map value) => AiDraft(
    id: value['id'] as String,
    status: value['status'] as String,
    changes: (value['changes'] as List? ?? const [])
        .map((item) => AiDraftChange.fromJson(item as Map))
        .toList(),
    warnings: (value['warnings'] as List? ?? const [])
        .map((item) => AiPlanningWarning.fromJson(item as Map))
        .toList(),
  );

  final String id;
  final String status;
  final List<AiDraftChange> changes;
  final List<AiPlanningWarning> warnings;
}

class AiTurnResult {
  const AiTurnResult({
    required this.sessionId,
    required this.draft,
    required this.summary,
    required this.questions,
    required this.warnings,
    required this.quota,
    this.requirements = const [],
    this.repaired = false,
    this.exceptions = const [],
    this.exceptionsRevision,
    this.exceptionsStale = false,
  });

  factory AiTurnResult.fromJson(Map value) => AiTurnResult(
    sessionId: value['sessionId'] as String,
    draft: AiDraft.fromJson(value['draft'] as Map),
    summary: (value['summary'] ?? '').toString(),
    questions: (value['questions'] as List? ?? const [])
        .map((item) => item.toString())
        .toList(),
    warnings: (value['warnings'] as List? ?? const [])
        .map(
          (item) => item is Map
              ? (item['message'] ?? '').toString()
              : item.toString(),
        )
        .toList(),
    quota: AiQuota.fromJson(value['quota'] as Map),
    requirements: (value['requirements'] as List? ?? const [])
        .map((r) => AiRequirement.fromJson(r as Map))
        .toList(),
    repaired: value['repaired'] == true,
    exceptions: (value['exceptions'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
    exceptionsRevision: value['exceptionsRevision']?.toString(),
    exceptionsStale: value['exceptionsStale'] == true,
  );

  final String sessionId;
  final AiDraft draft;
  final String summary;
  final List<String> questions;
  final List<String> warnings;
  final AiQuota quota;
  final List<AiRequirement> requirements;
  final bool repaired;
  final List<Map<String, dynamic>> exceptions;
  final String? exceptionsRevision;
  final bool exceptionsStale;

  AiTurnResult withDraft(
    AiDraft draft, {
    String? summary,
    bool confirmed = false,
  }) => AiTurnResult(
    sessionId: sessionId,
    draft: draft,
    summary: summary ?? this.summary,
    questions: const [],
    warnings: draft.warnings.map((w) => w.message).toList(),
    quota: quota,
    requirements: confirmed
        ? requirements.map((r) => r.asConfirmed).toList()
        : requirements,
    exceptions: confirmed ? const [] : exceptions,
    exceptionsRevision: confirmed ? null : exceptionsRevision,
    exceptionsStale: confirmed ? false : exceptionsStale,
  );

  String get outcome => draft.changes.isNotEmpty
      ? 'proposal'
      : questions.isNotEmpty
      ? 'clarification'
      : 'no_change';
}

class AiSessionSummary {
  const AiSessionSummary({
    required this.id,
    required this.status,
    required this.mode,
    required this.firstMessage,
    required this.summary,
    required this.hasPendingDraft,
    required this.createdAt,
    required this.updatedAt,
    required this.expiresAt,
    this.currentDraftId,
  });

  factory AiSessionSummary.fromJson(Map value) => AiSessionSummary(
    id: value['id'].toString(),
    status: AiSessionStatusX.fromWire(value['status']),
    mode: (value['mode'] ?? 'hosted').toString(),
    firstMessage: (value['firstMessage'] ?? '').toString(),
    summary: (value['summary'] ?? '').toString(),
    hasPendingDraft: value['hasPendingDraft'] == true,
    currentDraftId: value['currentDraftId']?.toString(),
    createdAt: _dateTime(value['createdAt']),
    updatedAt: _dateTime(value['updatedAt']),
    expiresAt: _dateTime(value['expiresAt']),
  );

  final String id;
  final AiSessionStatus status;
  final String mode;
  final String firstMessage;
  final String summary;
  final bool hasPendingDraft;
  final String? currentDraftId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime expiresAt;
}

class AiConversationTurn {
  const AiConversationTurn({
    required this.id,
    required this.input,
    required this.summary,
    required this.questions,
    required this.warnings,
    required this.createdAt,
    this.draft,
  });

  factory AiConversationTurn.fromJson(Map value) {
    final proposal = value['proposal'] is Map
        ? value['proposal'] as Map
        : const {};
    return AiConversationTurn(
      id: value['id'].toString(),
      input: (value['input'] ?? '').toString(),
      summary: (proposal['summary'] ?? '').toString(),
      questions: (proposal['questions'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      warnings: (proposal['warnings'] as List? ?? const [])
          .map(
            (item) => item is Map
                ? (item['message'] ?? '').toString()
                : item.toString(),
          )
          .toList(),
      draft: value['draft'] is Map
          ? AiDraft.fromJson(value['draft'] as Map)
          : null,
      createdAt: _dateTime(value['createdAt']),
    );
  }

  final String id;
  final String input;
  final String summary;
  final List<String> questions;
  final List<String> warnings;
  final AiDraft? draft;
  final DateTime createdAt;
}

class AiSessionDetail {
  const AiSessionDetail({
    required this.id,
    required this.status,
    required this.mode,
    required this.startDate,
    required this.endDate,
    required this.createdAt,
    required this.updatedAt,
    required this.expiresAt,
    required this.turns,
    this.currentDraftId,
    this.currentDraft,
    this.requirements = const [],
    this.applications = const [],
    this.exceptions = const [],
    this.exceptionsRevision,
    this.exceptionsStale = false,
  });

  factory AiSessionDetail.fromJson(Map value) => AiSessionDetail(
    id: value['id'].toString(),
    status: AiSessionStatusX.fromWire(value['status']),
    mode: (value['mode'] ?? 'hosted').toString(),
    startDate: DateTime.parse(value['startDate'].toString()),
    endDate: DateTime.parse(value['endDate'].toString()),
    currentDraftId: value['currentDraftId']?.toString(),
    createdAt: _dateTime(value['createdAt']),
    updatedAt: _dateTime(value['updatedAt']),
    expiresAt: _dateTime(value['expiresAt']),
    turns: (value['turns'] as List? ?? const [])
        .map((item) => AiConversationTurn.fromJson(item as Map))
        .toList(),
    currentDraft: value['currentDraft'] is Map
        ? AiDraft.fromJson(value['currentDraft'] as Map)
        : null,
    requirements: (value['requirements'] as List? ?? const [])
        .map((r) => AiRequirement.fromJson(r as Map))
        .toList(),
    applications: (value['applications'] as List? ?? const [])
        .map((r) => AiApplication.fromJson(r as Map))
        .toList(),
    exceptions: (value['exceptions'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
    exceptionsRevision: value['exceptionsRevision']?.toString(),
    exceptionsStale: value['exceptionsStale'] == true,
  );

  final String id;
  final AiSessionStatus status;
  final String mode;
  final DateTime startDate;
  final DateTime endDate;
  final String? currentDraftId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime expiresAt;
  final List<AiConversationTurn> turns;
  final AiDraft? currentDraft;
  final List<AiRequirement> requirements;
  final List<AiApplication> applications;
  final List<Map<String, dynamic>> exceptions;
  final String? exceptionsRevision;
  final bool exceptionsStale;
}

String aiMinuteLabel(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class AiRequirement {
  const AiRequirement({
    required this.id,
    required this.kind,
    required this.value,
    this.taskId,
    this.taskTitle,
    this.source = '',
    this.confirmed = false,
  });
  factory AiRequirement.fromJson(Map value) => AiRequirement(
    id: value['id'].toString(),
    kind: value['kind'].toString(),
    value: value['value'] as int,
    taskId: value['taskId'] as int?,
    taskTitle: value['taskTitle']?.toString(),
    source: (value['source'] ?? '').toString(),
    confirmed: value['confirmed'] == true,
  );
  final String id, kind, source;
  final int value;
  final int? taskId;
  final String? taskTitle;
  final bool confirmed;
  AiRequirement get asConfirmed => AiRequirement(
    id: id,
    kind: kind,
    value: value,
    taskId: taskId,
    taskTitle: taskTitle,
    source: source,
    confirmed: true,
  );
  String get label => switch (kind) {
    'start_minute' =>
      '${taskId == null ? '' : '${taskTitle ?? '任务'} · '}${aiMinuteLabel(value)} 后安排',
    'end_minute' =>
      '${taskId == null ? '' : '${taskTitle ?? '任务'} · '}${aiMinuteLabel(value)} 前结束',
    'break_minutes' => '安排之间休息 $value 分钟',
    'task_duration' => '${taskTitle ?? '任务'} · 预计 $value 分钟',
    'preserve_task' => '${taskTitle ?? '任务'} · 保持原安排',
    _ => '本次时间要求',
  };
  Map<String, dynamic> get manualValue => {
    'kind': kind,
    'taskId': taskId,
    'value': value,
  };
}

class AiApplyResult {
  const AiApplyResult({
    required this.applicationId,
    required this.applied,
    this.remainingDraft,
  });
  factory AiApplyResult.fromJson(Map value) => AiApplyResult(
    applicationId: value['applicationId'].toString(),
    applied: value['applied'] as int,
    remainingDraft: value['remainingDraft'] is Map
        ? AiDraft.fromJson(value['remainingDraft'] as Map)
        : null,
  );
  final String applicationId;
  final int applied;
  final AiDraft? remainingDraft;
}

class AiApplication {
  const AiApplication({
    required this.id,
    this.status = 'applied',
    this.applied = 0,
    this.draftId,
  });
  factory AiApplication.fromJson(Map value) => AiApplication(
    id: value['id'].toString(),
    status: value['status'].toString(),
    applied: (value['applied'] ?? 0) as int,
    draftId: value['draft_id']?.toString(),
  );
  final String id, status;
  final int applied;
  final String? draftId;
}
