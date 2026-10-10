import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sembast/sembast_memory.dart';
import 'package:plan_app/offline_sync.dart';
import 'package:plan_app/network_client.dart';
import 'package:plan_app/ddl_postponement.dart';
import 'package:plan_app/models.dart';
import 'package:plan_app/ai_calendar_guard.dart';

void main() {
  late Process server;
  late Map config;
  late OfflineSync sync;
  var online = true, loseResponse = false;
  Future<dynamic> transport(String method, String path, Map? body) async {
    if (!online) throw ApiException('offline');
    final request = http.Request(
      method,
      Uri.parse('http://127.0.0.1:${config['port']}$path'),
    );
    request.headers.addAll({
      'authorization': 'Bearer ${config['token']}',
      'content-type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);
    final client = http.Client();
    try {
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode >= 400) {
        throw ApiException(
          data['error'],
          code: data['code'],
          statusCode: response.statusCode,
          details: Map<String, dynamic>.from(data),
        );
      }
      if (loseResponse && method == 'POST') {
        loseResponse = false;
        online = false;
        throw ApiException('response lost');
      }
      return data;
    } finally {
      client.close();
    }
  }

  setUp(() async {
    server = await Process.start('node', [
      'tools/offline-fixture.js',
    ], workingDirectory: '../backend');
    final first = Completer<String>();
    server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!first.isCompleted) first.complete(line);
        });
    config = jsonDecode(await first.future) as Map;
    server.stderr.drain<void>();
    online = true;
    loseResponse = false;
    sync = OfflineSync(transport: transport);
    await sync.initialize(
      database: await databaseFactoryMemory.openDatabase(
        'test-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await sync.attach(config['uid'] as int, 'offline_fixture');
    await sync.sync();
  });
  tearDown(() async {
    await sync.sync();
    sync.dispose();
    server.kill();
    await server.exitCode;
  });
  test('AI planning waits for local edits and blocks when they cannot be synchronized', () async {
    online = false;
    await sync.mutate('POST', '/api/inbox', {'title': '尚未同步的任务'});
    await sync.sync();
    expect(sync.pendingCount, 1);
    await expectLater(
      ensureAiCalendarSynced(sync),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'AI_SYNC_REQUIRED'),
      ),
    );
    expect(sync.pendingCount, 1);
    online = true;
    await ensureAiCalendarSynced(sync);
    expect(sync.pendingCount, 0);
    expect((sync.read('/api/inbox') as List).single['title'], '尚未同步的任务');
  });
  test('offline chain creates list, task and schedule then edits and restores through real API', () async {
    online = false;
    final list = await sync.mutate('POST', '/api/lists', {'name': '离线清单'});
    await sync.sync();
    final task = await sync.mutate('POST', '/api/inbox', {
      'title': '离线任务',
      'list_id': list['id'],
      'schedule': {'date': '2026-09-20', 'start_min': 600, 'end_min': 660},
    });
    await sync.sync();
    final id = task['id'];
    await sync.mutate('PATCH', '/api/inbox/$id', {'title': '编辑后'});
    await sync.sync();
    await sync.mutate('DELETE', '/api/inbox/$id', {});
    await sync.sync();
    await sync.mutate('POST', '/api/trash/task/$id/restore', {});
    await sync.sync();
    expect(sync.pendingCount, 5);
    expect((sync.read('/api/inbox') as List).single['title'], '编辑后');
    online = true;
    await sync.sync();
    expect(sync.problem, isNull, reason: sync.exportPending());
    expect(
      sync.pendingCount,
      0,
      reason: '${sync.lastFailure}\n${sync.exportPending()}',
    );
    final row = (sync.read('/api/inbox') as List).single;
    expect(row['schedule']['start_min'], 600);
    expect(row['list_id'], greaterThan(0));
    // Existing editor/list pages may still hold the original temporary identifiers.
    await sync.mutate('PATCH', '/api/inbox/$id', {'notes': '旧页面继续编辑'});
    await sync.sync();
    expect(sync.pendingCount, 0);
    expect(
      (sync.read(
        '/api/lists/${list['id']}/tasks',
      ) as Map)['inbox'].single['notes'],
      '旧页面继续编辑',
    );
  });
  test('dragged block survives offline cross-day replay without changing DDL or reminder', () async {
    await sync.mutate('POST', '/api/inbox', {
      'title': '拖动验证',
      'notes': '保持备注',
      'due_date': '2090-02-03',
      'due_time': 900,
      'reminder_at': '2090-02-02T00:00:00.000Z',
      'schedule': {'date': '2090-02-01', 'start_min': 480, 'end_min': 545},
    });
    await sync.sync();
    final before = Map<String, dynamic>.from(
      (sync.read('/api/inbox') as List).single,
    );
    online = false;
    await sync.mutate('PATCH', '/api/blocks/${before['schedule']['id']}', {
      'date': '2090-02-02',
      'start_min': 525,
      'end_min': 590,
    });
    await sync.sync();
    expect(sync.pendingCount, 1);
    expect(
      (sync.read('/api/inbox') as List).single['schedule']['date'],
      '2090-02-02',
    );
    online = true;
    await sync.sync();
    expect(sync.pendingCount, 0, reason: sync.exportPending());
    final after = (await transport('GET', '/api/inbox', null) as List).single;
    for (final key in [
      'title',
      'notes',
      'due_date',
      'due_time',
      'reminder_at',
    ]) {
      expect(after[key], before[key], reason: key);
    }
    expect(after['schedule'], {
      ...before['schedule'],
      'date': '2090-02-02',
      'start_min': 525,
      'end_min': 590,
    });
  });
  test('overdue DDL postponement survives offline replay without moving its schedule', () async {
    await sync.mutate('POST', '/api/inbox', {
      'title': '过期任务',
      'due_date': '2020-01-01',
      'due_time': 600,
      'schedule': {'date': '2020-01-01', 'start_min': 480, 'end_min': 540},
    });
    await sync.sync();
    final before = Map<String, dynamic>.from(
      (sync.read('/api/inbox') as List).single,
    );
    final patch = postponedDdlPatch(
      InboxTask.fromJson(before),
      DateTime(2090, 2, 2),
    );
    online = false;
    await sync.mutate('PATCH', '/api/inbox/${before['id']}', patch);
    await sync.sync();
    expect(sync.pendingCount, 1);
    expect((sync.read('/api/inbox') as List).single['due_date'], '2090-02-02');
    online = true;
    await sync.sync();
    expect(sync.pendingCount, 0, reason: sync.exportPending());
    final after = (await transport('GET', '/api/inbox', null) as List).single;
    expect(after['due_date'], '2090-02-02');
    expect(after['due_time'], 600);
    expect(after['schedule'], before['schedule']);
  });
  test(
    'lost response retry after reopening retains queue and creates once',
    () async {
      final db = await databaseFactoryMemory.openDatabase('restart');
      sync.dispose();
      sync = OfflineSync(transport: transport);
      await sync.initialize(database: db);
      await sync.attach(config['uid'] as int, 'offline_fixture');
      await sync.sync();
      loseResponse = true;
      await sync.mutate('POST', '/api/inbox', {'title': '只创建一次'});
      await sync.sync();
      expect(sync.pendingCount, 1);
      final wire = jsonEncode(sync.pending.single['wire']);
      sync.dispose();
      sync = OfflineSync(transport: transport);
      await sync.initialize(database: db);
      expect(sync.pendingCount, 1);
      expect(jsonEncode(sync.pending.single['wire']), wire);
      online = true;
      await sync.sync();
      expect(sync.pendingCount, 0);
      expect((sync.read('/api/inbox') as List).length, 1);
    },
  );
  test('conflicting edit is preserved and explicitly resolved', () async {
    final created = await sync.mutate('POST', '/api/inbox', {'title': '原始'});
    await sync.sync();
    final id = (sync.read('/api/inbox') as List).single['id'];
    online = false;
    await sync.mutate('PATCH', '/api/inbox/${created['id']}', {'title': '我的'});
    await sync.sync();
    online = true;
    await transport('PATCH', '/api/inbox/$id', {'title': '另一设备'});
    await sync.sync();
    expect(sync.problem, isNotNull);
    expect(sync.pendingCount, 1);
    await sync.resolve(keepLocal: true);
    expect(sync.pendingCount, 0);
    expect((sync.read('/api/inbox') as List).single['title'], '我的');
  });
  test('revoked login preserves edits and same-account reauthentication resumes sync', () async {
    online = false;
    await sync.mutate('POST', '/api/inbox', {'title': '登录失效也保留'});
    await sync.sync();
    online = true;
    await transport('POST', '/api/auth/logout', {});
    await sync.sync();
    expect(sync.needsLogin, true);
    expect(sync.pendingCount, 1);
    expect((sync.read('/api/inbox') as List).single['title'], '登录失效也保留');
    final login = await transport('POST', '/api/auth/login', {
      'username': 'offline_fixture',
      'password': 'fixture-password-only',
    });
    config['token'] = login['token'];
    await sync.attach(config['uid'] as int, 'offline_fixture');
    await sync.sync();
    expect(sync.needsLogin, false);
    expect(sync.pendingCount, 0);
    expect((sync.read('/api/inbox') as List).length, 1);
  });
  test('public device does not persist and pending changes block logout/account switch', () async {
    final db = await databaseFactoryMemory.openDatabase('public');
    sync.dispose();
    sync = OfflineSync(transport: transport);
    await sync.initialize(database: db);
    await sync.attach(config['uid'] as int, 'offline_fixture', retain: false);
    await sync.sync();
    online = false;
    await sync.mutate('POST', '/api/inbox', {'title': '本机'});
    await sync.sync();
    expect(sync.clear(), throwsA(isA<ApiException>()));
    expect(sync.attach(999, 'other'), throwsA(isA<ApiException>()));
    sync.pauseForLogin();
    expect(sync.pendingCount, 1);
    expect(sync.ready, true);
    final reopened = OfflineSync(transport: transport);
    await reopened.initialize(database: db);
    expect(reopened.uid, isNull);
    reopened.dispose();
  });
  test(
    'unchanged background snapshot does not notify screens to reload',
    () async {
      sync.dispose();
      var changes = 0;
      sync = OfflineSync(transport: transport, onChanged: () => changes++);
      await sync.initialize(
        database: await databaseFactoryMemory.openDatabase(
          'unchanged-snapshot',
        ),
      );
      await sync.attach(config['uid'] as int, 'offline_fixture');
      await sync.sync();
      expect(changes, 1, reason: 'initial snapshot makes data available');

      changes = 0;
      await sync.sync();
      expect(changes, 0, reason: 'identical polling must not refresh the UI');
    },
  );
}
