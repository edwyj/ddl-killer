import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../community_state.dart';

class AiPlanningPreferencesScreen extends StatefulWidget {
  const AiPlanningPreferencesScreen({super.key});
  @override
  State<AiPlanningPreferencesScreen> createState() =>
      _AiPlanningPreferencesScreenState();
}

class _AiPlanningPreferencesScreenState
    extends State<AiPlanningPreferencesScreen> {
  int _start = 480, _end = 1320, _rest = 15;
  bool _loading = true, _busy = false, _dirty = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final cached = communityState.planningPreferences;
    if (cached != null) {
      _accept(cached);
      _loading = false;
    }
    unawaited(_load());
  }

  void _accept(Map<String, dynamic> p) {
    _start = p['startMinute'] as int;
    _end = p['endMinute'] as int;
    _rest = p['breakMinutes'] as int;
  }

  Future<void> _load() async {
    try {
      final p = await Api.instance.communityGet('/api/ai/preferences');
      if (!mounted) return;
      communityState.planningPreferences = p;
      setState(() {
        if (!_dirty) _accept(p);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is ApiException ? e.message : '偏好暂时无法刷新，可联网后重试';
        });
      }
    }
  }

  String _time(int value) =>
      '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  Future<void> _pick(bool start) async {
    final minute = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (minute ~/ 60) % 24, minute: minute % 60),
    );
    if (picked == null || !mounted) return;
    var value = ((picked.hour * 60 + picked.minute) / 15).round() * 15;
    if (!start && value == 0) value = 1440;
    setState(() {
      if (start) {
        _start = value.clamp(0, 1425);
      } else {
        _end = value.clamp(15, 1440);
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_start >= _end) {
      setState(() => _error = '结束时间需要晚于开始时间');
      return;
    }
    setState(() => _busy = true);
    try {
      final p = await Api.instance.savePlanningPreferences({
        'startMinute': _start,
        'endMinute': _end,
        'breakMinutes': _rest,
      });
      communityState.planningPreferences = p;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('安排偏好已保存')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '暂时无法保存，选择的时间会保留',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安排偏好')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '给计划留一点余地。',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        const Text('AI 默认在这个时段里寻找空闲时间，并在已有安排旁留出休息。你在对话里明确指定其他时间时，会优先考虑你的要求。'),
        const SizedBox(height: 24),
        if (_loading) const LinearProgressIndicator(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('可安排时段开始'),
          trailing: Text(_time(_start)),
          onTap: _busy || _loading ? null : () => _pick(true),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('可安排时段结束'),
          trailing: Text(_time(_end)),
          onTap: _busy || _loading ? null : () => _pick(false),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _rest,
          decoration: const InputDecoration(
            labelText: '已有安排前后的休息间隔',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final v in [0, 5, 10, 15, 30, 45, 60])
              DropdownMenuItem(value: v, child: Text(v == 0 ? '不预留' : '$v 分钟')),
          ],
          onChanged: _busy || _loading
              ? null
              : (v) => setState(() {
                  _rest = v!;
                  _dirty = true;
                }),
        ),
        const SizedBox(height: 16),
        const Text('按北京时间、15 分钟时间刻度安排。这是一般偏好，实际安排仍需你确认。'),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy || _loading ? null : _save,
          child: Text(_busy ? '正在保存…' : '保存偏好'),
        ),
      ],
    ),
  );
}
