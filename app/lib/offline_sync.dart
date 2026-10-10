import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import 'offline_database.dart';
import 'offline_projection.dart';
import 'network_client.dart';
import 'build_channel.dart';

typedef SyncTransport = Future<dynamic> Function(
  String method,
  String path,
  Map? body,
);

bool _sameJson(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (i) => i,
        ).every((i) => _sameJson(left[i], right[i]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameJson(left[key], right[key]),
        );
  }
  return left == right;
}

bool _sameSnapshot(Object? left, Object? right) {
  if (left is! Map || right is! Map) return _sameJson(left, right);
  final stableLeft = Map<Object?, Object?>.from(left)..remove('server_time');
  final stableRight = Map<Object?, Object?>.from(right)..remove('server_time');
  return _sameJson(stableLeft, stableRight);
}

class OfflineSync extends ChangeNotifier {
  OfflineSync({required this.transport, this.onChanged});
  final SyncTransport transport;
  final VoidCallback? onChanged;
  Database? _db;
  final _store = StoreRef<String, dynamic>('offline');
  Map<String, dynamic>? _state;
  Future<void> _serial = Future.value();
  Timer? _timer;
  bool _running = false;
  Future<void>? _flight;
  int _epoch = 0, _failures = 0;
  bool needsLogin = false;
  Object? lastFailure;
  String status = '正在准备离线数据';
  bool get ready => _state?['server'] != null;
  int? get uid => _state?['uid'] as int?;
  String? get username => _state?['username'] as String?;
  bool get persistent => _state?['persistent'] != false;
  List<Map<String, dynamic>> get pending =>
      _state == null ? [] : rows(_state!, 'queue');
  int get pendingCount => pending.length;
  Map<String, dynamic>? get problem =>
      pending.where((op) => op['error'] != null).firstOrNull;
  Future<T> _lock<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> initialize({Database? database}) async {
    _db = database ?? await openOfflineDatabase();
    final active = await _store.record('active').get(_db!);
    if (active is int) {
      final saved = await _store.record('account:$active').get(_db!);
      if (saved is Map) _state = copyMap(saved);
    }
    status = ready ? '本地数据已就绪，正在连接' : '首次使用需联网下载完整数据';
    notifyListeners();
  }

  Future<void> _save(Map<String, dynamic> state) async {
    if (state['persistent'] != false) {
      await _db!.transaction((txn) async {
        await _store.record('account:${state['uid']}').put(txn, state);
        await _store.record('active').put(txn, state['uid']);
      });
    }
    _state = state;
  }

  Future<void> attach(int account, String name, {bool retain = true}) =>
      _lock(() async {
        if (uid != null && uid != account && pendingCount > 0) {
          throw ApiException('本机账号 $username 还有待同步修改，请先登录原账号同步或导出');
        }
        _epoch++;
        needsLogin = false;
        Map<String, dynamic>? state;
        if (uid == account) state = _state;
        if (state == null) {
          final saved = await _store.record('account:$account').get(_db!);
          if (saved is Map) state = copyMap(saved);
        }
        state ??= {
          'uid': account,
          'username': name,
          'server': null,
          'queue': [],
          'nextId': -1,
        };
        if (!retain && ((state['queue'] as List?)?.isNotEmpty ?? false)) {
          throw ApiException('请先同步或导出本机修改，再切换为公共设备模式');
        }
        state = copyMap(state)
          ..addAll({'username': name, 'persistent': retain});
        if (!retain) {
          await _db!.transaction((txn) async {
            await _store.record('account:$account').delete(txn);
            await _store.record('active').delete(txn);
          });
        }
        await _save(state);
        status = ready ? '正在同步' : '正在下载完整离线数据';
        notifyListeners();
      });
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_running && !needsLogin) sync();
    });
    sync();
  }

  void pauseForLogin() {
    needsLogin = true;
    status = '登录已失效，本机修改已保留';
    notifyListeners();
  }

  Future<void> clear({bool discard = false}) => _lock(() async {
    if (pendingCount > 0 && !discard) {
      throw ApiException('还有 $pendingCount 项未同步，请先同步或导出');
    }
    _epoch++;
    _timer?.cancel();
    final account = uid;
    await _db!.transaction((txn) async {
      if (account != null) await _store.record('account:$account').delete(txn);
      await _store.record('active').delete(txn);
    });
    _state = null;
    needsLogin = false;
    status = '已清除本机离线数据';
    notifyListeners();
  });
  Map<String, dynamic> get view {
    if (!ready) throw ApiException('完整数据尚未下载，请联网后重试');
    final state = copyMap(_state!['server'] as Map);
    for (final op in pending) {
      applyLocal(state, op);
    }
    return state;
  }

  String _resolvedPath(String path) {
    final table = tableFor(path), id = pathId(path);
    final real = _state?['aliases']?['$table:$id'];
    if (real != null) return path.replaceFirst('/$id', '/$real');
    // List detail ends in /tasks rather than an entity id.
    final m = RegExp(r'^/api/lists/(-\d+)/tasks$').firstMatch(path);
    if (m != null) {
      final value = _state?['aliases']?['lists:${m.group(1)}'];
      if (value != null) return '/api/lists/$value/tasks';
    }
    return path;
  }

  dynamic read(String path) => readLocal(view, _resolvedPath(path));
  bool handles(String path) {
    final p = Uri.parse(path).path;
    return RegExp(r'^/api/(inbox|blocks|lists|trash|done)(/|$)').hasMatch(p) ||
        [
          '/api/day',
          '/api/days',
          '/api/week',
          '/api/schedule',
          '/api/me',
          '/api/stats',
          '/api/reminders',
          '/api/account/privacy',
        ].contains(p);
  }

  Future<dynamic> mutate(String method, String path, Map? body) async {
    final result = await _lock(() async {
      path = _resolvedPath(path);
      if (body != null) {
        body = copyMap(body!);
        final real = _state?['aliases']?['lists:${body!['list_id']}'];
        if (real != null) body!['list_id'] = real;
      }
      final current = view, state = copyMap(_state!);
      final queue = rows(state, 'queue');
      // Bulk removal expands to the exact records visible now, never future remote additions.
      if (method == 'DELETE' && (path == '/api/trash' || path == '/api/done')) {
        final values = (readLocal(current, path) as Map)['items'] as List;
        for (final item in values) {
          final target = path == '/api/done'
              ? '/api/done/${item['id']}'
              : '/api/trash/${item['kind']}/${item['id']}';
          final op = _operation(state, current, 'DELETE', target, {});
          queue.add(op);
          applyLocal(current, op);
        }
        state['queue'] = queue;
        await _save(state);
        return {'ok': true, 'tasks': values.length, 'blocks': 0};
      }
      final op = _operation(state, current, method, path, body ?? {});
      final result = applyLocal(current, op);
      queue.add(op);
      state['queue'] = queue;
      await _save(state);
      return result;
    });
    status = '待同步 $pendingCount 项';
    notifyListeners();
    onChanged?.call();
    unawaited(sync());
    return result;
  }

  Map<String, dynamic> _operation(
    Map state,
    Map current,
    String method,
    String path,
    Map body,
  ) {
    int next() {
      final id = state['nextId'] as int;
      state['nextId'] = id - 1;
      return id;
    }

    final creating =
        method == 'POST' &&
        ['/api/inbox', '/api/blocks', '/api/lists'].contains(path);
    final base = entityFor(current, path);
    if (!creating && base == null && path != '/api/schedule') {
      throw ApiException('内容不存在，请同步后重试');
    }
    if (method == 'DELETE' &&
        path.startsWith('/api/lists/') &&
        base?['system'] != null) {
      throw ApiException('系统清单不能删除');
    }
    final values = copyMap(body);
    for (final entry in {
      'title': 300,
      'name': 100,
      'notes': 10000,
      'color': 32,
      'emoji': 32,
    }.entries) {
      final value = values[entry.key];
      if (value != null && (value is! String || value.length > entry.value)) {
        throw ApiException('输入内容过长或格式不正确');
      }
    }
    if (values['reminder_at'] != null &&
        values['reminder_at'] != base?['reminder_at']) {
      final time = DateTime.tryParse(values['reminder_at'].toString());
      if (time == null || !time.isAfter(DateTime.now())) {
        throw ApiException('提醒时间必须晚于现在');
      }
    }
    if (values['title'] is String &&
        (values['title'] as String).trim().isEmpty) {
      throw ApiException('请填写任务标题');
    }
    final listId = values['list_id'];
    if (listId != null) {
      final list = findRow(current, 'lists', listId as int);
      if (list == null || ['trash', 'done'].contains(list['system'])) {
        throw ApiException('请选择有效清单');
      }
    }
    return {
      'id': const Uuid().v4(),
      'method': method,
      'path': path,
      'body': values,
      'base': base == null ? null : copyMap(base as Map),
      'at': DateTime.now().toUtc().toIso8601String(),
      if (creating) 'tempId': next(),
      if (path.contains('inbox') &&
          values['schedule'] != null &&
          base?['schedule'] == null)
        'blockTempId': next(),
    };
  }

  Future<void> sync() => _flight ??= _sync().whenComplete(() => _flight = null);
  Future<void> _acceptBetaSnapshot(Map<String, dynamic> snapshot, int epoch) =>
      _lock(() async {
        if (epoch != _epoch) return;
        if (snapshot['uid'] != uid) throw ApiException('同步账号不一致');
        final state = copyMap(_state!);
        if (state['server']?['generation'] != snapshot['generation']) {
          if (state['server'] != null) {
            await _store.record('beta-previous:$uid').put(_db!, state);
          }
          state['queue'] = [];
          state['aliases'] = {};
          state['nextId'] = -1;
        }
        state['server'] = snapshot;
        await _save(state);
      });
  Future<void> _sync() async {
    if (_running || _state == null || needsLogin) return;
    _running = true;
    final epoch = _epoch;
    status = '正在同步';
    notifyListeners();
    try {
      if (BuildChannel.beta || _state!['server']?['generation'] != null) {
        final fresh = Map<String, dynamic>.from(
          await transport('GET', '/api/sync/snapshot', null) as Map,
        );
        final changed = !_sameSnapshot(_state!['server'], fresh);
        await _acceptBetaSnapshot(fresh, epoch);
        if (changed) onChanged?.call();
      }
      while (epoch == _epoch && pending.isNotEmpty) {
        if (problem != null) {
          status = '有修改需要处理';
          return;
        }
        late Map<String, dynamic> wire, head;
        await _lock(() async {
          final state = copyMap(_state!);
          final queue = rows(state, 'queue');
          head = queue.first;
          wire = Map<String, dynamic>.from(
            head['wire'] as Map? ??
                {
                  'id': head['id'],
                  'uid': uid,
                  'method': head['method'],
                  'path': head['path'],
                  'body': head['body'],
                  'base': head['base'],
                },
          );
          if (state['server']?['generation'] != null) {
            wire['generation'] = state['server']['generation'];
          }
          head['wire'] = wire;
          queue[0] = head;
          state['queue'] = queue;
          await _save(state);
        });
        dynamic response;
        try {
          response = await transport('POST', '/api/sync/mutation', wire);
        } on ApiException catch (e) {
          if (e.code == 'DATASET_REFRESHED') {
            final fresh = Map<String, dynamic>.from(
              e.details!['snapshot'] as Map,
            );
            await _acceptBetaSnapshot(fresh, epoch);
            status = '测试数据已更新';
            onChanged?.call();
            return;
          }
          if (e.code == 'SYNC_CONFLICT' ||
              e.code == 'OP_ID_REUSED' ||
              (e.statusCode != null &&
                  e.statusCode! >= 400 &&
                  e.statusCode! < 500 &&
                  e.statusCode != 401 &&
                  e.statusCode != 429)) {
            await _lock(() async {
              if (epoch != _epoch) return;
              final state = copyMap(_state!), queue = rows(state, 'queue');
              queue[0]['error'] = e.message;
              queue[0]['conflict'] = e.details;
              state['queue'] = queue;
              await _save(state);
            });
            status = '有修改需要处理';
            return;
          }
          rethrow;
        }
        await _lock(() async {
          if (epoch != _epoch) return;
          final state = copyMap(_state!);
          final queue = rows(state, 'queue');
          final snap = Map<String, dynamic>.from(response['snapshot'] as Map);
          if (snap['uid'] != uid) throw ApiException('同步账号不一致');
          queue.removeAt(0);
          _mapIds(queue, head, response['result'] as Map);
          final aliases = Map<String, dynamic>.from(
            state['aliases'] as Map? ?? {},
          );
          final result = response['result'] as Map;
          if (head['tempId'] != null && result['id'] != null) {
            final type = head['path'] == '/api/inbox'
                ? 'tasks'
                : head['path'] == '/api/lists'
                ? 'lists'
                : 'blocks';
            aliases['$type:${head['tempId']}'] = result['id'];
          }
          if (head['blockTempId'] != null &&
              result['task']?['schedule']?['id'] != null) {
            aliases['blocks:${head['blockTempId']}'] =
                result['task']['schedule']['id'];
          }
          state['aliases'] = aliases;
          state['queue'] = queue;
          state['server'] = snap;
          await _save(state);
        });
      }
      if (epoch != _epoch) return;
      final previousSnapshot = _state!['server'];
      final snapshot = await transport('GET', '/api/sync/snapshot', null);
      await _lock(() async {
        if (epoch != _epoch) return;
        if (snapshot['uid'] != uid) {
          throw ApiException('请重新登录原账号后同步', code: 'SESSION_INVALID');
        }
        final state = copyMap(_state!);
        state['server'] = snapshot;
        state['username'] = snapshot['profile']['username'];
        state['lastSync'] = DateTime.now().toUtc().toIso8601String();
        await _save(state);
      });
      _failures = 0;
      status = pendingCount == 0 ? '已同步' : '待同步 $pendingCount 项';
      if (!_sameSnapshot(previousSnapshot, snapshot)) onChanged?.call();
    } on ApiException catch (e) {
      lastFailure = e;
      if (epoch != _epoch) return;
      if (e.code == 'SESSION_INVALID') {
        pauseForLogin();
      } else {
        _failures++;
        status = ready
            ? '离线 · ${pendingCount == 0 ? '本地数据可用' : '待同步 $pendingCount 项'}'
            : '首次下载未完成，请联网重试';
      }
    } catch (e) {
      lastFailure = e;
      _failures++;
      status = '同步未完成，修改仍保留在本机';
    } finally {
      _running = false;
      notifyListeners();
      if (_state != null && !needsLogin && problem == null) {
        _timer?.cancel();
        final delay = _failures == 0
            ? 15
            : (5 * (1 << _failures.clamp(0, 6))).clamp(10, 300);
        _timer = Timer(Duration(seconds: delay), sync);
      }
    }
  }

  void _mapIds(List<Map<String, dynamic>> queue, Map head, Map result) {
    final mappings = <String, Map<int, int>>{
      'tasks': {},
      'lists': {},
      'blocks': {},
    };
    final type = head['path'] == '/api/inbox'
        ? 'tasks'
        : head['path'] == '/api/lists'
        ? 'lists'
        : 'blocks';
    if (head['tempId'] != null && result['id'] != null) {
      mappings[type]![head['tempId'] as int] = result['id'] as int;
    }
    final bid = result['task']?['schedule']?['id'];
    if (head['blockTempId'] != null && bid != null) {
      mappings['blocks']![head['blockTempId'] as int] = bid as int;
    }
    for (final op in queue) {
      final table = tableFor(op['path'] as String),
          id = pathId(op['path'] as String);
      if (table != null && id != null && mappings[table]!.containsKey(id)) {
        op['path'] = (op['path'] as String).replaceFirst(
          '/$id',
          '/${mappings[table]![id]}',
        );
      }
      for (final field in ['body', 'base']) {
        final data = op[field];
        if (data is! Map) continue;
        if (table != null && data['id'] != null) {
          data['id'] = mappings[table]![data['id']] ?? data['id'];
        }
        if (data['list_id'] != null) {
          data['list_id'] =
              mappings['lists']![data['list_id']] ?? data['list_id'];
        }
        if (data['inbox_id'] != null) {
          data['inbox_id'] =
              mappings['tasks']![data['inbox_id']] ?? data['inbox_id'];
        }
        if (data['schedule'] is Map && data['schedule']['id'] != null) {
          data['schedule']['id'] =
              mappings['blocks']![data['schedule']['id']] ??
              data['schedule']['id'];
        }
      }
    }
  }

  Future<void> resolve({required bool keepLocal}) async {
    await _lock(() async {
      final state = copyMap(_state!), queue = rows(state, 'queue');
      if (queue.isEmpty) return;
      final op = queue.first;
      if (!keepLocal) {
        queue.removeAt(0);
      } else {
        final conflict = op['conflict'] as Map?;
        if (conflict == null || !conflict.containsKey('current')) {
          throw ApiException('该操作被服务器拒绝，请导出后选择使用线上版本，再重新编辑');
        }
        if (conflict['current'] == null) {
          throw ApiException('线上内容已删除，请先导出本机修改，再重新创建');
        }
        op['base'] = conflict['current'];
        op['id'] = const Uuid().v4();
        op.remove('wire');
        op.remove('error');
        op.remove('conflict');
        queue[0] = op;
      }
      state['queue'] = queue;
      await _save(state);
    });
    notifyListeners();
    onChanged?.call();
    await sync();
  }

  String exportPending() => const JsonEncoder.withIndent('  ').convert({
    'format': 'ddl-offline-recovery-v1',
    'uid': uid,
    'username': username,
    'snapshot': ready ? view : null,
    'pending': pending,
  });
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
