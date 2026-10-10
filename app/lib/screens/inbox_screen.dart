import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../widgets/task_editor.dart';

/// 「未排期」：还没落到日历某一天的任务。日历页右上角进来看一眼，顺手安排掉。
/// (这个页面以前叫「收件箱」，和清单页的收集箱不是同一个东西；
///  而且以前点一下只是把自己标成完成、并没有真的排上日程，属于假动作，已经去掉。)
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  List<InboxTask> _tasks = [];
  List<ListInfo> _lists = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final t = await Api.instance.inbox();
      // 有排期块 = 已经躺在日历上了；这个页面就是给「还没躺上去的」用的。
      final pending = t.where((e) => !e.done && e.schedule == null).toList();
      List<ListInfo> ls = _lists;
      try {
        ls = await Api.instance.lists();
      } catch (_) {
        // 拿不到清单只影响副标题的归属显示，不该让整页报错
      }
      if (mounted) {
        setState(() {
          _tasks = pending;
          _lists = ls;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = '网络错误';
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final changed = await showTaskEditor(context, lists: _lists);
    if (changed == true) _load();
  }

  /// 点一条就打开编辑器 —— 排到哪天、放进哪个清单都在里面，不另做一套。
  Future<void> _open(InboxTask t) async {
    ListInfo? owner;
    for (final l in _lists) {
      if (l.id == t.listId) owner = l;
    }
    final changed = await showTaskEditor(context, list: owner, task: t, lists: _lists);
    if (changed == true) _load();
  }

  String _subtitle(InboxTask t) {
    final parts = <String>[];
    for (final l in _lists) {
      if (l.id == t.listId) parts.add('${l.emoji} ${l.name}'.trim());
    }
    if (t.dueDate != null) parts.add('截止 ${dueLabel(t.dueDate, t.dueTime)}');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('未排期')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
              : _tasks.isEmpty
                  ? const Center(child: Text('都安排上了'))
                  : ListView.builder(
                      itemCount: _tasks.length,
                      itemBuilder: (ctx, i) {
                        final t = _tasks[i];
                        final sub = _subtitle(t);
                        return ListTile(
                          leading: Icon(
                            Icons.radio_button_unchecked,
                            color: prioColor(t.priority, fallback: scheme.primary),
                          ),
                          title: Text(t.title),
                          subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 12)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: '删除',
                            onPressed: () async {
                              final id = t.id;
                              if (id == null) return;
                              // 先取好 messenger：await 之后 context 还能不能用是不确定的
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await Api.instance.deleteInbox(id);
                                _load();
                              } on ApiException catch (e) {
                                messenger.showSnackBar(SnackBar(content: Text(e.message)));
                              }
                            },
                          ),
                          onTap: () => _open(t),
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
    );
  }
}
