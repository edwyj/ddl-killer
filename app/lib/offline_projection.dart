import 'dart:convert';

import 'package:intl/intl.dart';

Map<String, dynamic> copyMap(Map value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
List<Map<String, dynamic>> rows(Map state, String table) =>
    ((state[table] as List?) ?? [])
        .cast<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
Map<String, dynamic>? findRow(Map state, String table, int id) {
  for (final row in rows(state, table)) {
    if (row['id'] == id) return row;
  }
  return null;
}

String? tableFor(String path) {
  if (path.startsWith('/api/inbox/')) return 'tasks';
  if (path.startsWith('/api/blocks/')) return 'blocks';
  if (path.startsWith('/api/lists/')) return 'lists';
  if (path.startsWith('/api/trash/task/') || path.startsWith('/api/done/')) {
    return 'tasks';
  }
  if (path.startsWith('/api/trash/block/')) return 'blocks';
  return null;
}

int? pathId(String path) =>
    RegExp(r'/(-?\d+)(?:/restore)?$').firstMatch(path)?.group(1) == null
    ? null
    : int.parse(RegExp(r'/(-?\d+)(?:/restore)?$').firstMatch(path)!.group(1)!);
dynamic entityFor(Map state, String path) {
  final table = tableFor(path), id = pathId(path);
  if (table != null && id != null) return findRow(state, table, id);
  if (path == '/api/schedule') return state['schedule'];
  if (path == '/api/me') {
    return {
      'nickname': state['profile']?['nickname'],
      'avatar': state['profile']?['avatar'],
    };
  }
  if (path == '/api/account/privacy') {
    return {
      'hide_notification_content':
          state['profile']?['hide_notification_content'] != 0,
    };
  }
  return null;
}

void putRow(Map state, String table, Map row) {
  final data = rows(state, table);
  data.removeWhere((r) => r['id'] == row['id']);
  data.add(Map<String, dynamic>.from(row));
  state[table] = data;
}

void removeRow(Map state, String table, int id) {
  state[table] = rows(state, table)..removeWhere((r) => r['id'] == id);
}

/// Apply the user's intent to a snapshot. The queue and this projection are committed together.
Map<String, dynamic> applyLocal(Map<String, dynamic> state, Map op) {
  final path = op['path'] as String, method = op['method'] as String;
  final body = Map<String, dynamic>.from(op['body'] as Map? ?? {});
  final id = pathId(path) ?? op['tempId'] as int?;
  final at = op['at'] as String;
  String? table = tableFor(path);
  if (path == '/api/inbox') table = 'tasks';
  if (path == '/api/blocks') table = 'blocks';
  if (path == '/api/lists') table = 'lists';
  if (path == '/api/schedule') {
    state['schedule'] = copyMap(body);
    return {'ok': true};
  }
  if (path == '/api/me') {
    state['profile'] = {...state['profile'] as Map, ...body};
    return {'ok': true};
  }
  if (path == '/api/account/privacy') {
    (state['profile'] as Map)['hide_notification_content'] =
        body['hide_notification_content'] == true ? 1 : 0;
    return {'ok': true};
  }
  if (table == null || id == null) throw StateError('不支持的本地操作');
  final old = findRow(state, table, id);
  final creating = method == 'POST' && !path.endsWith('/restore');
  if (!creating && old == null) {
    return {
      'ok': true,
    }; // Keep missing-remote edits in the queue for explicit conflict handling.
  }
  final row = <String, dynamic>{
    'id': id,
    'user_id': state['uid'],
    'created_at': at,
    if (table != 'lists') ...{
      'done': 0,
      'notes': '',
      'deleted_at': null,
      'list_id': null,
    },
    if (table == 'tasks') ...{
      'priority': 0,
      'due_date': null,
      'due_time': null,
      'reminder_at': null,
      'done_at': null,
      'schedule': null,
    },
    if (table == 'blocks') ...{
      'inbox_id': null,
      'source': 'manual',
      'color': '#5C8DEF',
    },
    if (table == 'lists') ...{'system': null, 'color': '', 'emoji': ''},
    ...?old,
  };
  if (method == 'DELETE') {
    final permanent =
        path.startsWith('/api/trash/') ||
        path.startsWith('/api/done/') ||
        table == 'lists';
    if (table == 'blocks' && row['inbox_id'] != null) {
      final t = findRow(state, 'tasks', row['inbox_id'] as int);
      if (t != null) {
        t['schedule'] = null;
        putRow(state, 'tasks', t);
      }
      removeRow(state, 'blocks', id);
    } else if (permanent) {
      removeRow(state, table, id);
    } else {
      row['deleted_at'] = at;
      if (table == 'tasks') row['schedule'] = null;
      putRow(state, table, row);
    }
    if (table == 'tasks') {
      state['blocks'] = rows(state, 'blocks')
          .where((b) => !permanent || b['inbox_id'] != id)
          .map((b) => b['inbox_id'] == id ? {...b, 'deleted_at': at} : b)
          .toList();
    }
    if (table == 'lists') {
      for (final t in ['tasks', 'blocks']) {
        state[t] = rows(
          state,
          t,
        ).map((r) => r['list_id'] == id ? {...r, 'list_id': null} : r).toList();
      }
    }
    return {'ok': true};
  }
  if (path.endsWith('/restore')) {
    row['deleted_at'] = null;
    if (table == 'tasks') {
      final block = rows(
        state,
        'blocks',
      ).where((b) => b['inbox_id'] == id).firstOrNull;
      if (block != null) {
        row['schedule'] = {
          for (final k in ['id', 'date', 'start_min', 'end_min']) k: block[k],
        };
      }
    }
    putRow(state, table, row);
    if (table == 'tasks') {
      state['blocks'] = rows(state, 'blocks')
          .map((b) => b['inbox_id'] == id ? {...b, 'deleted_at': null} : b)
          .toList();
    }
    return {'ok': true};
  }
  row.addAll(body);
  if (row['title'] is String) row['title'] = (row['title'] as String).trim();
  if (row['name'] is String) row['name'] = (row['name'] as String).trim();
  if (table == 'tasks' &&
      !body.containsKey('reminder_at') &&
      old?['reminder_at'] != null &&
      old?['due_date'] != null &&
      (body.containsKey('due_date') || body.containsKey('due_time'))) {
    if (row['due_date'] == null) {
      row['reminder_at'] = null;
    } else {
      final before = DateTime.parse('${old!['due_date']}T00:00:00Z')
          .add(Duration(minutes: old['due_time'] as int? ?? 540));
      final after = DateTime.parse('${row['due_date']}T00:00:00Z')
          .add(Duration(minutes: row['due_time'] as int? ?? 540));
      row['reminder_at'] = DateTime.parse(old['reminder_at'])
          .add(after.difference(before))
          .toUtc()
          .toIso8601String();
    }
  }
  if (body.containsKey('done')) {
    row['done'] = body['done'] == true || body['done'] == 1 ? 1 : 0;
    if (row['done'] == 0) {
      row['done_at'] = null;
    } else if (old?['done'] != 1)
      row['done_at'] = at;
  }
  if (table == 'tasks') {
    if (body.containsKey('schedule')) {
      final s = body['schedule'];
      if (s == null) {
        state['blocks'] = rows(state, 'blocks')
          ..removeWhere((b) => b['inbox_id'] == id);
        row['schedule'] = null;
      } else {
        final linked = rows(
          state,
          'blocks',
        ).where((b) => b['inbox_id'] == id).firstOrNull;
        final bid = linked?['id'] ?? op['blockTempId'] ?? id;
        final block = <String, dynamic>{
          ...?(linked),
          'id': bid,
          'user_id': state['uid'],
          'inbox_id': id,
          'source': 'planned',
          'deleted_at': null,
          ...s as Map,
        };
        putRow(state, 'blocks', block);
        row['schedule'] = {'id': bid, ...s};
      }
    }
    for (final b in rows(
      state,
      'blocks',
    ).where((b) => b['inbox_id'] == id && b['deleted_at'] == null)) {
      b.addAll({
        'title': row['title'],
        'notes': row['notes'],
        'done': row['done'],
        'list_id': row['list_id'],
      });
      b['color'] ??=
          findRow(state, 'lists', row['list_id'] as int? ?? 0)?['color'] ??
          '#5C8DEF';
      putRow(state, 'blocks', b);
    }
  }
  if (table == 'blocks' && row['inbox_id'] != null) {
    final task = findRow(state, 'tasks', row['inbox_id'] as int);
    if (task != null) {
      for (final key in ['title', 'notes', 'done']) {
        if (body.containsKey(key)) task[key] = row[key];
      }
      task['schedule'] = {
        'id': id,
        'date': row['date'],
        'start_min': row['start_min'],
        'end_min': row['end_min'],
      };
      putRow(state, 'tasks', task);
    }
  }
  putRow(state, table, row);
  return {'ok': true, 'id': id, if (table == 'tasks') 'task': row};
}

int weekNumber(Map? schedule, String date) {
  final start = DateTime.parse(
    '${schedule?['semester_start'] ?? '2026-08-31'}T00:00:00Z',
  );
  final day = DateTime.parse('${date}T00:00:00Z');
  final diff = day.difference(start).inDays;
  return diff < 0 ? 0 : diff ~/ 7 + 1;
}

List<Map<String, dynamic>> dayItems(Map state, String date) {
  final schedule = state['schedule'] as Map?;
  final week = weekNumber(schedule, date),
      weekday = DateTime.parse(date).weekday;
  final items = <Map<String, dynamic>>[];
  const palette = [
    '#5C8DEF',
    '#E891A8',
    '#9B7EDE',
    '#E4C56B',
    '#6BB5A0',
    '#E89A6B',
    '#C48EDE',
    '#6BB5C9',
  ];
  if (schedule != null) {
    for (final course in schedule['courses'] as List? ?? []) {
      var hash = 0;
      for (final c in '${course['course_id']}'.codeUnits) {
        hash = (hash * 31 + c) & 0xffffffff;
      }
      for (final slot in course['slots'] as List? ?? []) {
        if (slot['weekday'] != weekday ||
            !(slot['weeks'] as List? ?? []).contains(week)) {
          continue;
        }
        final periods = slot['periods'] as List? ?? [],
            block = periods.isEmpty
                ? null
                : schedule['period_to_block']?['${periods.first}'];
        final times = schedule['period_times']?['$block'] as List?;
        int minute(dynamic s) {
          final p = '$s'.split(':');
          return int.parse(p[0]) * 60 + int.parse(p[1]);
        }

        items.add({
          'type': 'class',
          'title': course['name'],
          'teacher': course['teacher'] ?? '',
          'room': slot['room'] ?? '',
          'group': slot['group'] ?? '',
          'weeks': slot['weeks'],
          'weekNum': week,
          'block': block,
          'start_min': times == null ? 0 : minute(times[0]),
          'end_min': times == null ? 0 : minute(times[1]),
          'color': palette[hash % palette.length],
        });
      }
    }
  }
  for (final b in rows(
    state,
    'blocks',
  ).where((b) => b['date'] == date && b['deleted_at'] == null)) {
    items.add({...b, 'type': 'task'});
  }
  items.sort(
    (a, b) => (a['start_min'] as int).compareTo(b['start_min'] as int),
  );
  return items;
}

dynamic readLocal(Map state, String path) {
  final uri = Uri.parse(path), p = uri.path;
  final tasks = rows(
    state,
    'tasks',
  ).where((r) => r['deleted_at'] == null).toList();
  final blocks = rows(
    state,
    'blocks',
  ).where((r) => r['deleted_at'] == null).toList();
  if (p == '/api/me') {
    return {
      ...state['profile'] as Map,
      'has_schedule': state['schedule'] != null,
    };
  }
  if (p == '/api/account/privacy') {
    return {
      'hide_notification_content':
          state['profile']?['hide_notification_content'] != 0,
    };
  }
  if (p == '/api/schedule') return state['schedule'];
  if (p == '/api/inbox') {
    tasks.sort((a, b) {
      final pr = (b['priority'] as int).compareTo(a['priority'] as int);
      return pr != 0 ? pr : (b['id'] as int).compareTo(a['id'] as int);
    });
    return tasks;
  }
  if (p == '/api/done') {
    return {'items': tasks.where((r) => r['done'] == 1).toList()};
  }
  final trash = [
    ...rows(
      state,
      'tasks',
    ).where((r) => r['deleted_at'] != null).map((r) => {...r, 'kind': 'task'}),
    ...rows(state, 'blocks')
        .where((r) => r['deleted_at'] != null && r['inbox_id'] == null)
        .map((r) => {...r, 'kind': 'block'}),
  ];
  if (p == '/api/trash') return {'items': trash};
  if (p == '/api/lists') {
    return rows(state, 'lists')
        .map(
          (l) => {
            ...l,
            'task_count': l['system'] == 'trash'
                ? trash.length
                : l['system'] == 'done'
                ? tasks.where((t) => t['done'] == 1).length
                : [...tasks, ...blocks.where((b) => b['inbox_id'] == null)]
                      .where((t) => t['list_id'] == l['id'] && t['done'] == 0)
                      .length,
          },
        )
        .toList();
  }
  if (RegExp(r'^/api/lists/-?\d+/tasks$').hasMatch(p)) {
    final id = int.parse(p.split('/')[3]);
    return {
      'list': findRow(state, 'lists', id),
      'inbox': tasks.where((t) => t['list_id'] == id).toList(),
      'blocks': blocks
          .where((b) => b['list_id'] == id && b['inbox_id'] == null)
          .toList(),
    };
  }
  if (p == '/api/stats') {
    final all = [...tasks, ...blocks.where((b) => b['inbox_id'] == null)];
    return {
      'lists': rows(state, 'lists').where((l) => l['system'] == null).length,
      'todos': all.where((t) => t['done'] == 0).length,
      'done': all.where((t) => t['done'] == 1).length,
      'courses': (state['schedule']?['courses'] as List? ?? []).length,
    };
  }
  if (p == '/api/reminders') {
    return tasks
        .where(
          (t) =>
              t['done'] == 0 &&
              t['reminder_at'] != null &&
              DateTime.parse(t['reminder_at']).isAfter(DateTime.now()),
        )
        .map(
          (t) => {
            'id': t['id'],
            'title': state['profile']?['hide_notification_content'] != 0
                ? '你有一项任务需要处理'
                : t['title'],
            'reminder_at': t['reminder_at'],
          },
        )
        .toList();
  }
  if (p == '/api/day') {
    final date = uri.queryParameters['date']!;
    return {'date': date, 'timeline': dayItems(state, date)};
  }
  if (p == '/api/days' || p == '/api/week') {
    var start = DateTime.parse(uri.queryParameters['start']!);
    var count = int.tryParse(uri.queryParameters['count'] ?? '7') ?? 7;
    if (p == '/api/week') {
      start = start.subtract(Duration(days: start.weekday - 1));
      count = 7;
    }
    final days = List.generate(count, (i) {
      final d = start.add(Duration(days: i));
      final date = DateFormat('yyyy-MM-dd').format(d);
      return {
        'date': date,
        'weekday': d.weekday,
        'timeline': dayItems(state, date),
      };
    });
    return {
      'days': days,
      'weekNum': weekNumber(
        state['schedule'] as Map?,
        DateFormat('yyyy-MM-dd').format(start),
      ),
    };
  }
  throw StateError('未缓存该接口：$path');
}
