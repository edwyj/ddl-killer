import 'network_client.dart';

import 'dart:convert';

import 'offline_sync.dart';
import 'offline_platform.dart' as offline_platform;

import 'package:flutter/foundation.dart';

export 'network_client.dart' show ApiException;
import 'models.dart';
import 'models/mcp_connection.dart';
import 'models/ai_planner.dart';
import 'plan_bus.dart';
import 'build_channel.dart';
import 'ai_calendar_guard.dart';

/// 后端 API 客户端。base 可用 --dart-define=API_BASE=... 覆盖(默认走公网域名)
class Api {
  static const String _baseOverride = String.fromEnvironment('API_BASE');
  static final String base = BuildChannel.beta
      ? BuildChannel.origin
      : _baseOverride.isNotEmpty
      ? _baseOverride
      : (kIsWeb ? Uri.base.origin : 'https://ddlkiller.com');

  static final Api instance = Api._();
  final network = NetworkClient();
  late final offline = OfflineSync(
    transport: (method, path, body) =>
        network.request(method, _u(path), token, body),
    onChanged: PlanBus.instance.bump,
  );
  final emailRevision = ValueNotifier<int>(0);
  String? _token;
  String? get token => _token;
  void Function(String?, String?)? onSessionChanged;
  VoidCallback? onUnauthorized;
  set token(String? value) {
    final old = _token;
    _token = value;
    if (old != value) {
      network.reset();
      onSessionChanged?.call(old, value);
    }
  }

  Api._();

  Uri _u(String path) => Uri.parse('$base$path');

  /// 返回 JSON 解码结果(可能是 Map 或 List)
  Future<dynamic> _req(
    String method,
    String path, [
    Map? body,
    Duration? timeout,
  ]) async {
    final session = token;
    if (method == 'POST' &&
        (path == '/api/ai/sessions' ||
            RegExp(r'^/api/ai/sessions/[^/]+/turns$').hasMatch(path) ||
            RegExp(r'^/api/ai/drafts/[^/]+/apply$').hasMatch(path) ||
            RegExp(r'^/api/ai/applications/[^/]+/undo$').hasMatch(path))) {
      await ensureAiCalendarSynced(offline);
      if (session != token) throw ApiException('账号已切换，请重新加载');
    }
    if (offline.uid != null && offline.handles(path)) {
      if (!offline.ready) await offline.sync();
      return method == 'GET'
          ? offline.read(path)
          : offline.mutate(method, path, body);
    }
    dynamic result;
    try {
      result = await network.request(method, _u(path), session, body, timeout);
    } on ApiException catch (e) {
      if (e.code == 'SESSION_INVALID' && session != null && session == token) {
        onUnauthorized?.call();
      }
      rethrow;
    }
    if (session != token) throw ApiException('账号已切换，请重新加载');
    return result;
  }

  Future<void> login(
    String username,
    String password, {
    bool retain = true,
  }) async {
    if (offline.pendingCount > 0 && offline.username != username) {
      throw ApiException('请先登录 ${offline.username}，同步或导出本机修改后再切换账号');
    }
    final r = await _req('POST', '/api/auth/login', {
      'username': username,
      'password': password,
      if (kIsWeb) 'client': 'web',
    });
    token = kIsWeb ? 'web:${(r as Map)['uid']}' : (r as Map)['token'] as String;
    final uid = kIsWeb
        ? r['uid'] as int
        : (jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(token!.split('.')[1])),
                ),
              ) as Map)['uid']
              as int;
    await offline.attach(uid, username, retain: retain);
    if (retain) await offline_platform.requestPersistence();
    await offline.sync();
    offline.start();
  }

  Future<void> logout({bool all = false, bool discard = false}) async {
    if (offline.pendingCount > 0 && !discard) {
      throw ApiException('还有 ${offline.pendingCount} 项待同步，请在同步状态中处理或导出后再退出');
    }
    try {
      await _req('POST', all ? '/api/auth/logout-all' : '/api/auth/logout', {});
    } on ApiException catch (e) {
      if (e.code != 'SESSION_INVALID') rethrow;
    }
    await offline.clear(discard: discard);
  }

  Future<Map<String, dynamic>> exportAccount(String password) async =>
      Map<String, dynamic>.from(
        await _req('POST', '/api/account/export', {'password': password})
            as Map,
      );
  Future<void> deleteAccount(String password, String confirmation) async {
    if (offline.pendingCount > 0) throw ApiException('请先同步或导出并处理本机修改，再注销账号');
    await _req('DELETE', '/api/account', {
      'password': password,
      'confirmation': confirmation,
    });
  }

  Future<bool> hideNotificationContent() async =>
      (await _req('GET', '/api/account/privacy')
              as Map)['hide_notification_content']
          as bool;
  Future<void> setHideNotificationContent(bool value) async => _req(
    'PATCH',
    '/api/account/privacy',
    {'hide_notification_content': value},
  );

  Future<void> register(
    String username,
    String password, {
    required String email,
    required String requestId,
    required String code,
  }) async {
    await _req('POST', '/api/auth/register', {
      'username': username,
      'password': password,
      'email': email,
      'request_id': requestId,
      'code': code,
    });
  }

  Future<Map<String, dynamic>> requestRegistrationEmail(
    String email,
    String captchaId,
    String captchaCode,
  ) async => Map<String, dynamic>.from(
    await _req('POST', '/api/auth/email/register', {
      'email': email,
      'captcha_id': captchaId,
      'captcha_code': captchaCode,
    }),
  );
  Future<Map<String, dynamic>> accountEmail() async =>
      Map<String, dynamic>.from(await _req('GET', '/api/account/email'));
  Future<Map<String, dynamic>> requestEmailCode(
    String email, {
    String? password,
    String? captchaId,
    String? captchaCode,
  }) async => Map<String, dynamic>.from(
    await _req(
      'POST',
      password == null ? '/api/auth/email/reset' : '/api/account/email/code',
      {
        'email': email,
        if (password != null) 'password': password,
        if (captchaId != null) 'captcha_id': captchaId,
        if (captchaCode != null) 'captcha_code': captchaCode,
      },
    ),
  );
  Future<void> bindEmail(Map<String, dynamic> body) async {
    await _req('POST', '/api/account/email', body);
    emailRevision.value++;
  }

  Future<String> resetPassword(Map<String, dynamic> body) async {
    final r = await _req('POST', '/api/auth/email/reset-confirm', body) as Map;
    return r['username'] as String;
  }

  /// 拉取一张新图形验证码(一次性，用后即焚；失败后需重新拉取)。
  Future<({String id, String svg})> captcha() async {
    final r = await _req('GET', '/api/auth/captcha') as Map;
    return (id: r['id'] as String, svg: r['svg'] as String);
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _req('POST', '/api/auth/password', {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  Future<void> importSchedule(Map<String, dynamic> schedule) async {
    await _req('PUT', '/api/schedule', schedule);
    // 导入成功后通知各面板重拉：「我的」页(已导入/课程数)与周视图都在 IndexedStack 里
    // 常驻,不 bump 就永远停在旧数据上(失败时不能 bump,否则白刷一遍)。
    PlanBus.instance.bump();
  }

  Future<({String username, String nickname, String avatar, bool hasSchedule})>
  me() async {
    final r = await _req('GET', '/api/me') as Map;
    return (
      username: r['username'] as String,
      nickname: (r['nickname'] ?? '') as String,
      avatar: (r['avatar'] ?? '') as String,
      hasSchedule: r['has_schedule'] as bool? ?? false,
    );
  }

  /// 更新个人资料(昵称/头像 spec)。只传需要改的字段，未传的键不下发。
  Future<void> updateProfile({String? nickname, String? avatar}) async {
    await _req('PATCH', '/api/me', {
      if (nickname != null) 'nickname': nickname,
      if (avatar != null) 'avatar': avatar,
    });
    PlanBus.instance.bump();
  }

  /// 个人页统计：{lists, todos, done, courses} 全为整数。
  Future<Map<String, dynamic>> stats() async =>
      Map<String, dynamic>.from(await _req('GET', '/api/stats') as Map);

  Future<void> checkHealth() async => _req('GET', '/api/health');

  Future<AiAssistantSettings> aiSettings() async {
    final settings = await _req('GET', '/api/ai/settings') as Map;
    final quota = AiQuota.fromJson(await _req('GET', '/api/ai/quota') as Map);
    AiProviderSummary? provider;
    try {
      provider = AiProviderSummary.fromJson(
        await _req('GET', '/api/ai/provider') as Map,
      );
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
    }
    return AiAssistantSettings(
      mode: settings['mode'] == 'byok'
          ? AiProviderMode.byok
          : AiProviderMode.hosted,
      provider: provider,
      quota: quota,
      featureEnabled: settings['featureEnabled'] as bool? ?? false,
    );
  }

  Future<void> setAiMode(AiProviderMode mode, {String? password}) async {
    await _req('PATCH', '/api/ai/settings', {
      'mode': mode.name,
      if (password?.isNotEmpty == true) 'password': password,
    });
  }

  Future<AiProviderSummary> saveAiProvider(AiProviderInput input) async =>
      AiProviderSummary.fromJson(
        await _req('PUT', '/api/ai/provider', {
          'provider': input.provider,
          'base_url': input.baseUrl,
          'model': input.model,
          'key': input.key,
          if (input.password?.isNotEmpty == true) 'password': input.password,
        }) as Map,
      );

  Future<void> testAiProvider({String? password}) async {
    await _req('POST', '/api/ai/provider/test', {
      if (password?.isNotEmpty == true) 'password': password,
    });
  }

  Future<void> deleteAiProvider({String? password}) async {
    await _req('DELETE', '/api/ai/provider', {
      if (password?.isNotEmpty == true) 'password': password,
    });
  }

  Future<String> transcribeVoice(List<int> wav) async {
    final result = await _req('POST', '/api/ai/speech', {
      'audio_base64': base64Encode(wav),
    }, const Duration(seconds: 30)) as Map;
    return result['text'] as String;
  }

  Future<AiQuota> aiQuota() async =>
      AiQuota.fromJson(await _req('GET', '/api/ai/quota') as Map);

  Future<Map<String, dynamic>> previewAiInvite(String code) async =>
      Map<String, dynamic>.from(
        await _req('POST', '/api/ai/invites/preview', {'code': code}) as Map,
      );

  Future<void> redeemAiInvite(String code) async =>
      _req('POST', '/api/ai/invites/redeem', {'code': code});

  Future<Map<String, dynamic>> communityGet(String path) async =>
      Map<String, dynamic>.from(await _req('GET', path) as Map);
  Future<Map<String, dynamic>> communityPost(
    String path,
    Map<String, dynamic> body,
  ) async => Map<String, dynamic>.from(await _req('POST', path, body) as Map);
  Future<void> deleteFeedbackFiles(int id) async =>
      _req('DELETE', '/api/feedback/$id/files');
  Future<Map<String, dynamic>> savePlanningPreferences(
    Map<String, dynamic> preferences,
  ) async => Map<String, dynamic>.from(
    await _req('PATCH', '/api/ai/preferences', preferences) as Map,
  );

  Future<AiTurnResult> createAiSession({
    required String message,
    required DateTime start,
    required DateTime end,
    Map<String, dynamic> configuration = const {},
  }) async => AiTurnResult.fromJson(
    await _req('POST', '/api/ai/sessions', {
      'message': message,
      'startDate': _dateOnly(start),
      'endDate': _dateOnly(end),
      ...configuration,
    }, const Duration(seconds: 65)) as Map,
  );

  Future<AiTurnResult> addAiTurn(
    String sessionId,
    String message, {
    Map<String, dynamic> configuration = const {},
  }) async => AiTurnResult.fromJson(
    await _req('POST', '/api/ai/sessions/$sessionId/turns', {
      'message': message,
      ...configuration,
    }, const Duration(seconds: 65)) as Map,
  );

  Future<List<AiSessionSummary>> listAiSessions() async {
    final response = await _req('GET', '/api/ai/sessions?limit=20') as Map;
    return (response['items'] as List? ?? const [])
        .map((item) => AiSessionSummary.fromJson(item as Map))
        .toList();
  }

  Future<AiSessionDetail> getAiSession(String sessionId) async =>
      AiSessionDetail.fromJson(
        await _req('GET', '/api/ai/sessions/$sessionId') as Map,
      );

  Future<void> closeAiSession(String sessionId) async {
    await _req('POST', '/api/ai/sessions/$sessionId/close', {});
  }

  Future<void> deleteAiSession(String sessionId) async {
    await _req('DELETE', '/api/ai/sessions/$sessionId', {});
  }

  Future<void> discardAiSession(String sessionId) async {
    await deleteAiSession(sessionId);
  }

  Future<void> applyAiDraft(String draftId) async {
    final session = token;
    await _req('POST', '/api/ai/drafts/$draftId/apply', {});
    await _refreshAfterAiWrite(session);
  }

  Future<Map<String, dynamic>> aiPlanningOptions() async =>
      Map<String, dynamic>.from(await _req('GET', '/api/ai/options') as Map);
  Future<AiApplyResult> applySelectedAiDraft(
    String draftId,
    List<String> ids,
    List<String> confirmed,
  ) async {
    final session = token;
    final result = AiApplyResult.fromJson(
      await _req('POST', '/api/ai/drafts/$draftId/apply', {
        'selectedChangeIds': ids,
        'confirmedRequirementIds': confirmed,
      }) as Map,
    );
    await _refreshAfterAiWrite(session);
    return result;
  }

  Future<void> undoAiApplication(String id) async {
    final session = token;
    await _req('POST', '/api/ai/applications/$id/undo', {});
    await _refreshAfterAiWrite(session);
  }

  Future<void> _refreshAfterAiWrite(String? session) async {
    if (session != token) throw ApiException('账号已切换，请重新加载');
    await offline.sync();
    if (session != token) throw ApiException('账号已切换，请重新加载');
    PlanBus.instance.bump();
  }

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  Future<List<TimelineItem>> day(String date) async {
    final r = await _req('GET', '/api/day?date=$date') as Map;
    final list = (r['timeline'] as List<dynamic>? ?? []);
    return list
        .map((e) => TimelineItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 一整周(周视图):start 为周内任意一天，后端返回周一~周日 7 天
  Future<List<WeekDay>> week(String start) async {
    final r = await _req('GET', '/api/week?start=$start') as Map;
    final days = (r['days'] as List<dynamic>? ?? []);
    return days.map((d) => _weekDay(d)).toList();
  }

  /// 任意连续 N 天(范围视图):start 起点，count 天数。
  /// 同时返回后端算好的周数(周末无课也有准确周数，避免 App 靠猜课程块推不出)。
  Future<(List<WeekDay>, int?)> rangeWithWeek(String start, int count) async {
    final r = await _req('GET', '/api/days?start=$start&count=$count') as Map;
    final days = (r['days'] as List<dynamic>? ?? []);
    return (days.map((d) => _weekDay(d)).toList(), r['weekNum'] as int?);
  }

  /// 任意连续 N 天(范围视图):start 起点，count 天数(仅日期，不带周数)
  Future<List<WeekDay>> range(String start, int count) async {
    final r = await _req('GET', '/api/days?start=$start&count=$count') as Map;
    final days = (r['days'] as List<dynamic>? ?? []);
    return days.map((d) => _weekDay(d)).toList();
  }

  static WeekDay _weekDay(dynamic d) {
    final m = d as Map<String, dynamic>;
    final items = (m['timeline'] as List<dynamic>? ?? [])
        .map((e) => TimelineItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return WeekDay(
      date: (m['date'] ?? '').toString(),
      weekday: (m['weekday'] ?? 1) as int,
      items: items,
    );
  }

  Future<int> addBlock(
    String date,
    int startMin,
    int endMin,
    String title, {
    String color = '#8e7cc3',
    String? note,
  }) async {
    final r = await _req('POST', '/api/blocks', {
      'date': date,
      'start_min': startMin,
      'end_min': endMin,
      'title': title,
      'color': color,
      if (note != null && note.isNotEmpty) 'notes': note,
    }) as Map;
    PlanBus.instance.bump();
    return r['id'] as int;
  }

  Future<void> updateBlock(
    int id, {
    String? date,
    int? startMin,
    int? endMin,
    String? title,
    bool? done,
    String? color,
    String? note,
  }) async {
    await _req('PATCH', '/api/blocks/$id', {
      if (date != null) 'date': date,
      if (startMin != null) 'start_min': startMin,
      if (endMin != null) 'end_min': endMin,
      if (title != null) 'title': title,
      if (done != null) 'done': done,
      if (color != null) 'color': color,
      if (note != null) 'notes': note,
    });
    PlanBus.instance.bump();
  }

  Future<void> deleteBlock(int id) async {
    await _req('DELETE', '/api/blocks/$id');
    PlanBus.instance.bump();
  }

  Future<List<InboxTask>> inbox() async {
    final r = await _req('GET', '/api/inbox');
    return (r as List)
        .map((e) => InboxTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> addInbox(
    String title, {
    int priority = 0,
    int? listId,
    String? dueDate,
    int? dueTime,
    String? notes,
  }) async {
    final r = await _req('POST', '/api/inbox', {
      'title': title,
      'priority': priority,
      if (listId != null) 'list_id': listId,
      if (dueDate != null) 'due_date': dueDate,
      if (dueTime != null) 'due_time': dueTime,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    }) as Map;
    PlanBus.instance.bump();
    return r['id'] as int;
  }

  Future<List<dynamic>> reminders() async =>
      await _req('GET', '/api/reminders') as List;
  Future<String> pushKey() async =>
      (await _req('GET', '/api/push/key') as Map)['publicKey'] as String;
  Future<void> subscribePush(Map subscription) async {
    await _req('POST', '/api/push/subscribe', subscription);
  }

  Future<void> savePlannedTask(int? id, Map<String, dynamic> body) async {
    await _req(
      id == null ? 'POST' : 'PATCH',
      id == null ? '/api/inbox' : '/api/inbox/$id',
      body,
    );
    PlanBus.instance.bump();
  }

  // ---------- 清单 ----------
  Future<List<ListInfo>> lists() async {
    final r = await _req('GET', '/api/lists');
    return (r as List)
        .map((e) => ListInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> addList(
    String name, {
    String emoji = '',
    String color = '',
  }) async {
    final r = await _req('POST', '/api/lists', {
      'name': name,
      'emoji': emoji,
      'color': color,
    }) as Map;
    PlanBus.instance.bump();
    return r['id'] as int;
  }

  Future<void> updateList(
    int id, {
    String? name,
    String? emoji,
    String? color,
  }) async {
    await _req('PATCH', '/api/lists/$id', {
      if (name != null) 'name': name,
      if (emoji != null) 'emoji': emoji,
      if (color != null) 'color': color,
    });
    PlanBus.instance.bump();
  }

  Future<void> deleteList(int id) async {
    await _req('DELETE', '/api/lists/$id');
    PlanBus.instance.bump();
  }

  Future<Map<String, dynamic>> listDetail(int id) async {
    return Map<String, dynamic>.from(
      await _req('GET', '/api/lists/$id/tasks') as Map,
    );
  }

  Future<void> updateInbox(
    int id, {
    String? title,
    bool? done,
    int? priority,
    String? notes,
    String? dueDate,
    int? dueTime,
  }) async {
    final body = <String, dynamic>{
      if (title != null) 'title': title,
      if (done != null) 'done': done,
      if (priority != null) 'priority': priority,
      if (notes != null) 'notes': notes,
    };
    // 因 Dart 无法区分"没传"与"显式传 null"，约定：dueDate == null 表示不改动(省略键)；
    // dueDate == '' (空串) 表示清除整个 ddl；否则设置日期(可带时刻 dueTime，null=只到日期)。
    // 这样 _toggle 等只传 done 的调用不会误清 ddl。
    if (dueDate != null) {
      if (dueDate.isEmpty) {
        body['due_date'] = null;
        body['due_time'] = null;
      } else {
        body['due_date'] = dueDate;
        body['due_time'] = dueTime;
      }
    }
    await _req('PATCH', '/api/inbox/$id', body);
    PlanBus.instance.bump();
  }

  Future<void> deleteInbox(int id) async {
    await _req('DELETE', '/api/inbox/$id');
    PlanBus.instance.bump();
  }

  // ---------- 回收站 / 已完成 ----------
  /// 回收站内容：被删的任务 + 日历上直接建的独立时间块。后端按 7 天自动清。
  Future<List<TrashItem>> trash() async {
    final r = await _req('GET', '/api/trash') as Map;
    return (r['items'] as List<dynamic>? ?? [])
        .map((e) => TrashItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 还原一条(kind: 'task' | 'block')。任务的时间块会跟着一起回来。
  Future<void> restoreTrash(String kind, int id) async {
    await _req('POST', '/api/trash/$kind/$id/restore');
    PlanBus.instance.bump();
  }

  /// 永久删除一条，不可撤销。
  Future<void> deleteTrashItem(String kind, int id) async {
    await _req('DELETE', '/api/trash/$kind/$id');
    PlanBus.instance.bump();
  }

  /// 清空回收站，不可撤销。返回清掉的条数 {blocks, tasks}。
  Future<Map<String, dynamic>> emptyTrash() async {
    final r = Map<String, dynamic>.from(
      await _req('DELETE', '/api/trash') as Map,
    );
    PlanBus.instance.bump();
    return r;
  }

  /// 已完成：打完勾、还没到 3 天清理期的任务。
  Future<List<InboxTask>> doneTasks() async {
    final r = await _req('GET', '/api/done') as Map;
    return (r['items'] as List<dynamic>? ?? [])
        .map((e) => InboxTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 永久删除一条已完成任务，不可撤销(不经过回收站)。
  Future<void> deleteDoneTask(int id) async {
    await _req('DELETE', '/api/done/$id');
    PlanBus.instance.bump();
  }

  /// 清空已完成，不可撤销。
  Future<void> emptyDone() async {
    await _req('DELETE', '/api/done');
    PlanBus.instance.bump();
  }

  Future<List<McpConnection>> mcpClients() async =>
      (await _req('GET', '/api/mcp/clients') as List)
          .map(
            (e) => McpConnection.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
  Future<CreatedMcpToken> createMcpClient({
    required String name,
    required List<String> scopes,
    required DateTime expiresAt,
    required String password,
  }) async {
    final r = Map<String, dynamic>.from(
      await _req('POST', '/api/mcp/clients', {
        'name': name,
        'scopes': scopes,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'password': password,
      }) as Map,
    );
    return CreatedMcpToken(
      token: r['token'] as String,
      client: McpConnection.fromJson(
        Map<String, dynamic>.from(r['client'] as Map),
      ),
    );
  }

  Future<void> revokeMcpClient(String id, String password) =>
      _req('DELETE', '/api/mcp/clients/$id', {'password': password});
  Future<List<McpAuditEntry>> mcpAudit() async =>
      (await _req('GET', '/api/mcp/audit') as List)
          .map(
            (e) => McpAuditEntry.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
  Future<Map<String, dynamic>> oauthRequest(
    String requestId,
  ) async => Map<String, dynamic>.from(
    await _req(
      'GET',
      '/api/mcp/oauth/authorize?request_id=${Uri.encodeQueryComponent(requestId)}',
    ) as Map,
  );
  Future<Uri> approveOauth(String requestId, List<String> scopes) async =>
      Uri.parse(
        (await _req('POST', '/api/mcp/oauth/authorize', {
              'request_id': requestId,
              'approved': true,
              'scopes': scopes,
            }) as Map)['redirect_uri']
            as String,
      );
  Future<String> beginOauth(Uri uri) async =>
      (await _req('GET', '/api/mcp/oauth/authorize?${uri.query}')
              as Map)['requestId']
          as String;
  Future<Uri> denyOauth(String requestId) async => Uri.parse(
    (await _req('POST', '/api/mcp/oauth/authorize', {
          'request_id': requestId,
          'approved': false,
        }) as Map)['redirect_uri']
        as String,
  );
}
