import 'package:flutter/material.dart';

import '../models/ai_planner.dart';

class AiRequirementsEditor extends StatefulWidget {
  const AiRequirementsEditor({
    super.key,
    required this.options,
    required this.requirements,
    this.exceptions = const [],
    this.exceptionsRevision,
  });
  final Map<String, dynamic> options;
  final List<AiRequirement> requirements;
  final List<Map<String, dynamic>> exceptions;
  final String? exceptionsRevision;
  @override
  State<AiRequirementsEditor> createState() => _AiRequirementsEditorState();
}

class _AiRequirementsEditorState extends State<AiRequirementsEditor> {
  late int start, end, rest;
  final durations = <int, TextEditingController>{};
  final taskStarts = <int, int>{}, taskEnds = <int, int>{};
  bool get exceptionsStale =>
      widget.exceptions.isNotEmpty &&
      widget.exceptionsRevision != widget.options['revision'];
  final preserved = <int>{}, exceptions = <String>{};
  String? error;
  List<Map> get tasks => (widget.options['tasks'] as List? ?? []).cast<Map>();
  String title(int id) => tasks
      .firstWhere((t) => t['id'] == id, orElse: () => {'title': '任务'})['title']
      .toString();
  List<int> get restOptions =>
      {0, 5, 10, 15, 20, 30, 45, 60, rest}.toList()..sort();
  @override
  void initState() {
    super.initState();
    final prefs = widget.options['preferences'] as Map;
    start = prefs['startMinute'] as int;
    end = prefs['endMinute'] as int;
    rest = prefs['breakMinutes'] as int;
    for (final r in widget.requirements) {
      switch (r.kind) {
        case 'start_minute':
          if (r.taskId == null) {
            start = r.value;
          } else {
            taskStarts[r.taskId!] = r.value;
            durations.putIfAbsent(r.taskId!, () => TextEditingController());
          }
        case 'end_minute':
          if (r.taskId == null) {
            end = r.value;
          } else {
            taskEnds[r.taskId!] = r.value;
            durations.putIfAbsent(r.taskId!, () => TextEditingController());
          }
        case 'break_minutes':
          rest = r.value;
        case 'task_duration':
          durations.remove(r.taskId!)?.dispose();
          durations[r.taskId!] = TextEditingController(
            text: r.value.toString(),
          );
        case 'preserve_task':
          preserved.add(r.taskId!);
          durations.putIfAbsent(r.taskId!, () => TextEditingController());
      }
    }
    for (final e in widget.exceptions) {
      durations.putIfAbsent(e['taskId'] as int, () => TextEditingController());
      if (!exceptionsStale) exceptions.add('${e['taskId']}:${e['kind']}');
    }
  }

  @override
  void dispose() {
    for (final c in durations.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> chooseTime(bool isStart) async {
    final value = isStart ? start : end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (value ~/ 60).clamp(0, 23),
        minute: value % 60,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        if (isStart) {
          start = picked.hour * 60 + picked.minute;
        } else {
          end = picked.hour * 60 + picked.minute;
        }
      });
    }
  }

  Future<void> chooseTaskTime(int id, bool isStart) async {
    final value =
        (isStart ? taskStarts[id] : taskEnds[id]) ?? (isStart ? start : end);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (value ~/ 60).clamp(0, 23),
        minute: value % 60,
      ),
    );
    if (picked != null && mounted) {
      setState(
        () => (isStart ? taskStarts : taskEnds)[id] =
            picked.hour * 60 + picked.minute,
      );
    }
  }

  void save() {
    if (start >= end) {
      setState(() => error = '结束时间需要晚于开始时间');
      return;
    }
    final values = <Map<String, dynamic>>[
      {'kind': 'start_minute', 'taskId': null, 'value': start},
      {'kind': 'end_minute', 'taskId': null, 'value': end},
      {'kind': 'break_minutes', 'taskId': null, 'value': rest},
    ];
    for (final entry in durations.entries) {
      final taskStart = taskStarts[entry.key], taskEnd = taskEnds[entry.key];
      if ((taskStart ?? 0) >= (taskEnd ?? 1440)) {
        setState(() => error = '任务的结束时间需要晚于开始时间');
        return;
      }
      if (taskStart != null) {
        values.add({
          'kind': 'start_minute',
          'taskId': entry.key,
          'value': taskStart,
        });
      }
      if (taskEnd != null) {
        values.add({
          'kind': 'end_minute',
          'taskId': entry.key,
          'value': taskEnd,
        });
      }
      final raw = entry.value.text.trim();
      if (raw.isNotEmpty) {
        final value = int.tryParse(raw);
        if (value == null || value < 1 || value > 10080) {
          setState(() => error = '预计用时请填写1至10080分钟，或留空');
          return;
        }
        values.add({
          'kind': 'task_duration',
          'taskId': entry.key,
          'value': value,
        });
      }
      if (preserved.contains(entry.key)) {
        values.add({'kind': 'preserve_task', 'taskId': entry.key, 'value': 1});
      }
    }
    if (values.length > 20) {
      setState(() => error = '本次要求较多，请减少一些任务设置');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'manualRequirements': values,
      'exceptionsRevision': widget.options['revision'],
      'exceptions': exceptions.map((e) {
        final parts = e.split(':');
        return {'taskId': int.parse(parts[0]), 'kind': parts[1]};
      }).toList(),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本次要求'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('只用于这次对话，不会改动任务的长期预计用时。'),
            if (exceptionsStale)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('日程已经变化，之前的冲突例外已失效；如仍需要，请重新勾选。'),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => chooseTime(true),
                    child: Text('${aiMinuteLabel(start)} 开始'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => chooseTime(false),
                    child: Text('${aiMinuteLabel(end)} 结束'),
                  ),
                ),
              ],
            ),
            DropdownButtonFormField<int>(
              initialValue: rest,
              decoration: const InputDecoration(labelText: '两项安排之间的休息'),
              items: restOptions
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v 分钟')))
                  .toList(),
              onChanged: (v) => setState(() => rest = v!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey(durations.length),
              isExpanded: true,
              menuMaxHeight: 280,
              decoration: const InputDecoration(labelText: '添加任务要求'),
              items: tasks
                  .where((t) => !durations.containsKey(t['id']))
                  .map(
                    (t) => DropdownMenuItem(
                      value: t['id'] as int,
                      child: Text(
                        t['title'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id != null) {
                  setState(() => durations[id] = TextEditingController());
                }
              },
            ),
            for (final entry in durations.entries)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title(entry.key),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: '移除任务要求',
                          onPressed: () => setState(() {
                            durations.remove(entry.key)?.dispose();
                            preserved.remove(entry.key);
                            taskStarts.remove(entry.key);
                            taskEnds.remove(entry.key);
                            exceptions.removeWhere(
                              (e) => e.startsWith('${entry.key}:'),
                            );
                          }),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    TextField(
                      controller: entry.value,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '本次预计用时（分钟）',
                        hintText: '留空沿用任务设置',
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final isStart in [true, false])
                          InputChip(
                            label: Text(
                              '${(isStart ? taskStarts : taskEnds)[entry.key] == null ? '不限' : aiMinuteLabel((isStart ? taskStarts : taskEnds)[entry.key]!)}${isStart ? '开始' : '结束'}',
                            ),
                            onPressed: () => chooseTaskTime(entry.key, isStart),
                            onDeleted:
                                (isStart ? taskStarts : taskEnds).containsKey(
                                  entry.key,
                                )
                                ? () => setState(
                                    () => (isStart ? taskStarts : taskEnds)
                                        .remove(entry.key),
                                  )
                                : null,
                          ),
                      ],
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('保持原安排'),
                      value: preserved.contains(entry.key),
                      onChanged: (v) => setState(() {
                        v == true
                            ? preserved.add(entry.key)
                            : preserved.remove(entry.key);
                      }),
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('允许的冲突例外'),
                      subtitle: const Text('课程和过去时间始终不可占用'),
                      children: [
                        for (final e in const {
                          'overlap': '允许与其他安排重叠',
                          'deadline': '允许在截止时间后完成',
                          'rest': '允许不留休息时间',
                          'window': '允许超出本次可用时段',
                        }.entries)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(e.value),
                            value: exceptions.contains('${entry.key}:${e.key}'),
                            onChanged: (v) => setState(() {
                              final key = '${entry.key}:${e.key}';
                              v == true
                                  ? exceptions.add(key)
                                  : exceptions.remove(key);
                            }),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: save, child: const Text('用于本次规划')),
    ],
  );
}
