import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../models.dart';
import '../plan_bus.dart';
import '../widgets/task_editor.dart';
import '../widgets/postpone_ddl.dart';
import '../ddl_postponement.dart';
import '../widgets/course_details_sheet.dart';
import 'block_editor.dart';
import '../widgets/today_agenda_tile.dart';
import '../widgets/task_completion_control.dart';

/// 清单板块：左侧抽屉导航 + body 按当前选区渲染任务列表。
/// 选区共六种：今天 / 收集箱 / 其他 / 你的清单 / 已完成 / 回收站。
/// 收集箱是唯一「真容器」——任务真的带着它的 list_id；已完成和回收站是算出来的，只做入口。
class ListScreen extends StatefulWidget {
  const ListScreen({super.key, this.now});
  final DateTime Function()? now;

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> with WidgetsBindingObserver {
  List<ListInfo> _lists = []; // 抽屉里的清单(含系统清单)
  bool _loading = true;
  String? _error;

  // 当前选区：today / inbox / dateOnly / done / trash / list
  String _view = 'today';
  int? _listId; // 仅 _view == 'list' 时有值
  String _selName = '今天';
  bool _doneCollapsed = true;

  // 全量任务：今天/收集箱/其他三个视图共用，同时也是抽屉角标的来源。
  // 无论当前在哪个视图都拉一次 —— 否则切到回收站时抽屉角标会集体归零。
  List<InboxTask> _inbox = [];
  Map<String, dynamic>? _detail; // 清单视图用的 {list, blocks, inbox}
  List<InboxTask> _doneTasks = []; // 已完成视图
  List<TrashItem> _trash = []; // 回收站视图
  List<TimelineItem> _todayItems = [];
  String _todayDate = '';
  int _loadRevision = 0;
  String? _loadedView;
  Timer? _dayTimer;

  DateTime get _now => widget.now?.call() ?? DateTime.now();
  String get _date => DateFormat('yyyy-MM-dd').format(_now);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watchDate();
    PlanBus.instance.revision.addListener(_onDataChanged);
    _load();
    _loadLists();
  }

  @override
  void dispose() {
    _dayTimer?.cancel();
    _loadRevision++;
    WidgetsBinding.instance.removeObserver(this);
    PlanBus.instance.revision.removeListener(_onDataChanged);
    super.dispose();
  }

  /// 任一面板改动数据后，清单页重拉 任务体 + 抽屉清单(跨面板自动同步)。
  void _onDataChanged() {
    if (!mounted) return;
    _load(silent: true);
    _loadLists();
  }

  void _watchDate() {
    _dayTimer?.cancel();
    final now = _now;
    _dayTimer = Timer(
      DateTime(now.year, now.month, now.day + 1).difference(now),
      () {
        if (!mounted) return;
        _load();
        _watchDate();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: _todayDate == _date);
      _watchDate();
    }
  }

  Future<void> _loadLists() async {
    try {
      final l = await Api.instance.lists();
      if (mounted) setState(() => _lists = l);
    } catch (_) {
      // 抽屉列表失败不阻塞 body
    }
  }

  /// 系统清单按标记找，不按名字找 —— 用户改名了也照样认得出来。
  ListInfo? _system(String key) {
    for (final l in _lists) {
      if (l.system == key) return l;
    }
    return null;
  }

  Future<void> _load({bool silent = false}) async {
    final id = _listId;
    final view = _view, date = _date, revision = ++_loadRevision;
    setState(() {
      if (!silent ||
          _loadedView != view ||
          (view == 'today' && _todayDate != date)) {
        _loading = true;
      }
      _error = null;
    });
    try {
      final result = await Future.wait<Object>([
        Api.instance.inbox(),
        if (view == 'today') Api.instance.day(date),
        if (view == 'list') Api.instance.listDetail(id!),
        if (view == 'done') Api.instance.doneTasks(),
        if (view == 'trash') Api.instance.trash(),
      ]);
      if (!mounted || revision != _loadRevision) return;
      _inbox = result.first as List<InboxTask>;
      _loadedView = view;
      if (view == 'today') {
        _todayDate = date;
        _todayItems = result[1] as List<TimelineItem>;
        _todayItems.sort(
          (a, b) => a.startMin.compareTo(b.startMin) != 0
              ? a.startMin.compareTo(b.startMin)
              : a.endMin.compareTo(b.endMin),
        );
      } else {
        _todayDate =
            ''; // A different view may have changed today's arrangements.
      }
      switch (view) {
        case 'list':
          _detail = result[1] as Map<String, dynamic>;
          final list = _detail?['list'] as Map<String, dynamic>?;
          _selName = '${list?['emoji'] ?? ''} ${list?['name'] ?? ''}'.trim();
        case 'done':
          _doneTasks = result[1] as List<InboxTask>;
          _selName = '已完成';
        case 'trash':
          _trash = result[1] as List<TrashItem>;
          _selName = '回收站';
        case 'inbox':
          _selName = '收集箱';
        case 'dateOnly':
          _selName = '其他';
        default:
          _selName = '今天';
      }
      if (mounted) setState(() => _loading = false);
    } on ApiException catch (e) {
      if (mounted && revision == _loadRevision) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && revision == _loadRevision) {
        setState(() {
          _error = '网络错误: $e';
          _loading = false;
        });
      }
    }
  }

  // ---- 选区切换 ----
  void _select(String view, {int? listId}) {
    setState(() {
      _view = view;
      _listId = listId;
    });
    _load();
  }

  void _selectList(ListInfo l) {
    setState(() => _selName = '${l.emoji} ${l.name}'.trim());
    _select('list', listId: l.id);
  }

  // ---- 任务操作 ----
  Future<void> _toggle(InboxTask t) async {
    try {
      await Api.instance.updateInbox(t.id!, done: !t.done);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  ListInfo? _findList(int? id) {
    if (id == null) return null;
    for (final l in _lists) {
      if (l.id == id) return l;
    }
    return null;
  }

  Future<void> _addTask() async {
    bool changed;
    switch (_view) {
      case 'list':
        final id = _listId;
        final list = _findList(id) ?? ListInfo(id: id, name: _selName);
        changed = await showTaskEditor(context, list: list, lists: _lists);
      case 'inbox':
        // 收集箱是真清单，带上它的 id 才是真的「放进收集箱」
        changed = await showTaskEditor(
          context,
          list: _system('inbox'),
          lists: _lists,
        );
      case 'dateOnly':
        changed = await showTaskEditor(context, lists: _lists);
      default:
        changed =
            await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => BlockEditor(date: _date)),
            ) ==
            true;
    }
    if (changed) _load();
  }

  Future<void> _edit(InboxTask t) async {
    final changed = await showTaskEditor(
      context,
      list: _findList(t.listId),
      task: t,
      lists: _lists,
    );
    if (changed) _load();
  }

  List<InboxTask> _currentTasks() {
    switch (_view) {
      case 'list':
        return (_detail?['inbox'] as List<dynamic>? ?? [])
            .map((e) => InboxTask.fromJson(e as Map<String, dynamic>))
            .toList();
      case 'inbox':
        return _inbox.where((t) => t.listId == _system('inbox')?.id).toList();
      case 'dateOnly':
        return _inbox.where((t) => t.listId == null).toList();
      case 'done':
        return _doneTasks;
      default:
        return _todayReminders;
    }
  }

  List<InboxTask> get _todayReminders =>
      _inbox
          .where((t) => !t.done && t.dueDate == _date && t.schedule == null)
          .toList()
        ..sort((a, b) => (a.dueTime ?? 1440).compareTo(b.dueTime ?? 1440));

  Future<void> _editArrangement(TimelineItem item) async {
    if (item.type == 'class') {
      await showCourseDetails(context, item);
      return;
    }
    final task = _inbox.where((t) => t.schedule?['id'] == item.id).firstOrNull;
    if (task != null) {
      await _edit(task);
    } else {
      final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => BlockEditor(date: _todayDate, item: item),
        ),
      );
      if (changed == true && mounted) _load(silent: true);
    }
  }

  Future<void> _toggleArrangement(TimelineItem item) async {
    try {
      await Api.instance.updateBlock(item.id!, done: !item.done);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  // ---- 回收站 / 已完成 ----
  Future<void> _restore(TrashItem it) async {
    try {
      await Api.instance.restoreTrash(it.kind, it.id);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _purge(TrashItem it) async {
    final ok = await _confirm('永久删除「${it.title}」?', '删除后无法找回。');
    if (ok != true) return;
    try {
      await Api.instance.deleteTrashItem(it.kind, it.id);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _emptyTrash() async {
    final ok = await _confirm('清空回收站?', '里面的任务和时间块会被永久删除，无法找回。');
    if (ok != true) return;
    try {
      final r = await Api.instance.emptyTrash();
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已清空 ${r['tasks'] ?? 0} 个任务、${r['blocks'] ?? 0} 个时间块',
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _purgeDone(InboxTask t) async {
    final ok = await _confirm('永久删除「${t.title}」?', '不想删就取消，再点一下勾选框可以放回原清单。');
    if (ok != true) return;
    try {
      await Api.instance.deleteDoneTask(t.id!);
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _emptyDone() async {
    final ok = await _confirm('清空已完成?', '这些任务会被永久删除，无法找回。');
    if (ok != true) return;
    try {
      await Api.instance.emptyDone();
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE05858),
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );

  // ---- 清单操作 ----
  Future<void> _addList() async {
    final nameCtrl = TextEditingController();
    final emojiCtrl = TextEditingController();
    final color = ValueNotifier('#5C8DEF');
    const palette = [
      '#5C8DEF',
      '#E891A8',
      '#9B7EDE',
      '#E4C56B',
      '#6BB5A0',
      '#E89A6B',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('新建清单'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '清单名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emojiCtrl,
                decoration: const InputDecoration(hintText: 'emoji 图标(可选)'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => setState(() => color.value = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(
                            int.parse('FF${c.substring(1)}', radix: 16),
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color.value == c
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        await Api.instance.addList(
          nameCtrl.text.trim(),
          emoji: emojiCtrl.text.trim(),
          color: color.value,
        );
        _loadLists();
      } on ApiException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _editList(ListInfo l) async {
    if (l.id == null) return;
    final nameCtrl = TextEditingController(text: l.name);
    final emojiCtrl = TextEditingController(text: l.emoji);
    final color = ValueNotifier(l.color.isEmpty ? '#5C8DEF' : l.color);
    const palette = [
      '#5C8DEF',
      '#E891A8',
      '#9B7EDE',
      '#E4C56B',
      '#6BB5A0',
      '#E89A6B',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('编辑清单'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '清单名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emojiCtrl,
                decoration: const InputDecoration(hintText: 'emoji 图标(可选)'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => setState(() => color.value = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(
                            int.parse('FF${c.substring(1)}', radix: 16),
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color.value == c
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        await Api.instance.updateList(
          l.id!,
          name: nameCtrl.text.trim(),
          emoji: emojiCtrl.text.trim(),
          color: color.value,
        );
        _loadLists();
      } on ApiException catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _deleteList(ListInfo l) async {
    if (l.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除清单「${l.name}」?'),
        // 任务不会跟着走：清单只是归类，删掉归类不等于删掉东西。
        content: const Text('清单下的任务不会丢失，它们会脱离这个清单，在抽屉的「其他」里能找到。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (_listId == l.id) {
        // 删的是当前选中清单：先切走，否则 deleteList 触发 bus 时会去拉已删清单的 detail 而报错。
        setState(() {
          _view = 'dateOnly';
          _listId = null;
          _selName = '其他';
        });
      }
      await Api.instance.deleteList(l.id!); // bump → 监听已把 body+抽屉刷成最新
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTrash = _view == 'trash';
    final isDone = _view == 'done';
    return Scaffold(
      appBar: AppBar(
        title: Text(_selName),
        actions: [
          if (isTrash && _trash.isNotEmpty)
            TextButton(onPressed: _emptyTrash, child: const Text('清空')),
          if (isDone && _doneTasks.isNotEmpty)
            TextButton(onPressed: _emptyDone, child: const Text('清空')),
        ],
      ),
      drawer: _buildDrawer(scheme),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : isTrash
          ? _buildTrash(scheme)
          : _buildBody(scheme),
      // 回收站/已完成里没有「新建」这回事
      floatingActionButton: (isTrash || isDone)
          ? null
          : FloatingActionButton(
              onPressed: _addTask,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildDrawer(ColorScheme scheme) {
    final dateOnlyCount = _inbox
        .where((t) => t.listId == null && !t.done)
        .length;
    final inbox = _system('inbox');
    final done = _system('done');
    final trash = _system('trash');
    // 已完成/回收站是系统清单，不该出现在「你的清单」里
    final mine = _lists.where((l) => !l.isSystem).toList();

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.event_note, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    '清单',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _DrawerTile(
              icon: Icons.today_outlined,
              title: '今天',
              count: 0,
              selected: _view == 'today',
              onTap: () {
                Navigator.pop(context);
                _select('today');
              },
            ),
            _DrawerTile(
              icon: Icons.inbox_outlined,
              title: inbox?.name ?? '收集箱',
              count: inbox?.taskCount ?? 0,
              selected: _view == 'inbox',
              onTap: () {
                Navigator.pop(context);
                _select('inbox');
              },
            ),
            _DrawerTile(
              // 名字叫「其他」，图标就不该再是日历——那是在照搬旧名「仅日期」。
              icon: Icons.more_horiz,
              title: '其他',
              count: dateOnlyCount,
              selected: _view == 'dateOnly',
              onTap: () {
                Navigator.pop(context);
                _select('dateOnly');
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                '你的清单',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.outline,
                ),
              ),
            ),
            if (mine.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  '还没有清单',
                  style: TextStyle(color: scheme.outline, fontSize: 13),
                ),
              )
            else
              for (final l in mine)
                _ListDrawerTile(
                  list: l,
                  selected: _view == 'list' && _listId == l.id,
                  onTap: () {
                    Navigator.pop(context);
                    _selectList(l);
                  },
                  onEdit: () {
                    Navigator.pop(context);
                    _editList(l);
                  },
                  onDelete: () {
                    Navigator.pop(context);
                    _deleteList(l);
                  },
                ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: ListTile(
                leading: const Icon(Icons.add),
                title: const Text('添加清单'),
                onTap: () {
                  Navigator.pop(context);
                  _addList();
                },
              ),
            ),
            const Divider(height: 1),
            // 系统区：这两处是任务的落脚点，不是可以随便塞东西的清单
            _DrawerTile(
              icon: Icons.check_circle_outline,
              title: done?.name ?? '已完成',
              count: done?.taskCount ?? 0,
              selected: _view == 'done',
              onTap: () {
                Navigator.pop(context);
                _select('done');
              },
            ),
            _DrawerTile(
              icon: Icons.delete_outline,
              title: trash?.name ?? '回收站',
              count: trash?.taskCount ?? 0,
              selected: _view == 'trash',
              onTap: () {
                Navigator.pop(context);
                _select('trash');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_view == 'today') return _buildToday(scheme);
    final all = _currentTasks();
    final open = all.where((t) => !t.done).toList();
    final done = all.where((t) => t.done).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // 判空要看全部而不是只看未完成：一条任务都没完成时，下面那个收起来的
          // 「已完成」分组本来就渲染不出来，这里再提示一次反而对。
          if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 56,
                    color: scheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _view == 'done' ? '还没有完成的任务' : '没有待办',
                    style: TextStyle(color: scheme.outline),
                  ),
                ],
              ),
            ),
          for (final (label, group) in _bucketOpen(open)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: label == '已过期'
                          ? const Color(0xFFE05858)
                          : scheme.outline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.outline.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '${group.length}',
                      style: TextStyle(color: scheme.outline, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            for (final t in group)
              _TaskTile(
                task: t,
                listColor: _listColor(),
                onToggle: () => _toggle(t),
                onEdit: () => _edit(t),
              ),
          ],
          if (done.isNotEmpty) ...[
            // 「已完成」页面点进来就是要看这些任务的，标题栏已经写着「已完成」了，
            // 再来一行同名分组、还把内容收起来，等于让用户白点一次。
            if (_view != 'done')
              ListTile(
                title: Row(
                  children: [
                    Text(
                      '已完成',
                      style: TextStyle(
                        color: scheme.outline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.outline.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${done.length}',
                        style: TextStyle(color: scheme.outline, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                trailing: InkWell(
                  onTap: () => setState(() => _doneCollapsed = !_doneCollapsed),
                  child: Icon(
                    _doneCollapsed
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    color: scheme.outline,
                  ),
                ),
              ),
            if (_view == 'done' || !_doneCollapsed)
              for (final t in done)
                _TaskTile(
                  task: t,
                  listColor: _listColor(),
                  onToggle: () => _toggle(t),
                  onEdit: () => _edit(t),
                  // 在「已完成」视图里点勾=放回原清单，但那种任务终归要能彻底删掉
                  onPurge: _view == 'done' ? () => _purgeDone(t) : null,
                ),
          ],
        ],
      ),
    );
  }

  Widget _buildToday(ColorScheme scheme) {
    final reminders = _todayReminders;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          // 今天页和其他清单一样铺满可用宽度；别再套居中的窄栏，
          // 否则宽屏（电脑网页端）两侧会留下大片空白，只剩手机看着正常。
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${DateFormat('M月d日').format(DateTime.parse(_todayDate))} · ${cnWeekday(DateTime.parse(_todayDate))}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (_todayItems.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Icon(
                        Icons.event_available_outlined,
                        size: 40,
                        color: scheme.outline,
                      ),
                      const SizedBox(height: 12),
                      const Text('今天还没有排好的安排 🎀'),
                      const SizedBox(height: 8),
                      Text(
                        '把想做的事留一段时间，按自己的节奏来。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              for (final item in _todayItems)
                TodayAgendaTile(
                  item: item,
                  onOpen: () => _editArrangement(item),
                  onToggle: item.id == null
                      ? null
                      : () => _toggleArrangement(item),
                ),
              if (reminders.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  '今天截止 · 还未排时间',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '别忘了给这些事留一点时间。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                for (final task in reminders)
                  TodayDeadlineTile(
                    task: task,
                    now: () => _now,
                    listColor: _listColor(),
                    onToggle: () => _toggle(task),
                    onOpen: () => _edit(task),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 回收站：每条都能还原或永久删除，删除时刻写在副标题上。
  Widget _buildTrash(ColorScheme scheme) {
    if (_trash.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                children: [
                  Icon(Icons.delete_outline, size: 56, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text('回收站是空的', style: TextStyle(color: scheme.outline)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _trash.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '被删的任务和时间块在这里放 7 天，到期自动清掉。',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            );
          }
          final it = _trash[i - 1];
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: Icon(
                it.kind == 'block'
                    ? Icons.event_busy_outlined
                    : Icons.check_box_outline_blank,
                color: scheme.outline,
              ),
              title: Text(
                it.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (it.deletedLabel.isNotEmpty) '${it.deletedLabel} 删除',
                  if (it.kind == 'block' && it.date != null) it.date!,
                  if (it.kind == 'task' && it.dueDate != null)
                    '原定 ${it.dueDate}',
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '还原',
                    icon: const Icon(Icons.restore, size: 20),
                    onPressed: () => _restore(it),
                  ),
                  IconButton(
                    tooltip: '永久删除',
                    icon: const Icon(
                      Icons.delete_forever,
                      size: 20,
                      color: Color(0xFFE05858),
                    ),
                    onPressed: () => _purge(it),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 当前选区的清单配色(智能选区用主题主色)。
  Color _listColor() {
    final l = _findList(_listId);
    if (l != null) return _hex(l.color) ?? const Color(0xFF5C8DEF);
    return Theme.of(context).colorScheme.primary;
  }
}

class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerTile({
    required this.icon,
    required this.title,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        title,
        style: TextStyle(color: selected ? scheme.primary : null),
      ),
      trailing: count > 0
          ? Text(
              '$count',
              style: TextStyle(color: scheme.outline, fontSize: 13),
            )
          : null,
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.08),
      onTap: onTap,
    );
  }
}

class _ListDrawerTile extends StatelessWidget {
  final ListInfo list;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ListDrawerTile({
    required this.list,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _hex(list.color) ?? const Color(0xFF5C8DEF);
    return ListTile(
      leading: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          list.emoji.isNotEmpty ? list.emoji : '📋',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      title: Text(
        list.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${list.taskCount} 个任务',
        style: TextStyle(color: scheme.outline, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'del') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(
                value: 'del',
                child: Text('删除', style: TextStyle(color: Color(0xFFE05858))),
              ),
            ],
          ),
        ],
      ),
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.08),
      onTap: onTap,
    );
  }
}

Color? _hex(String hex) {
  if (hex.length < 7) return null;
  return Color(int.parse('FF${hex.substring(1)}', radix: 16));
}

/// 按截止时间把开放任务分组：已过期 / 今天 / 即将到来 / 无日期(已过期最上，越早在越严重)。
List<(String, List<InboxTask>)> _bucketOpen(List<InboxTask> open) {
  final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final overdue = <InboxTask>[];
  final today = <InboxTask>[];
  final upcoming = <InboxTask>[];
  final noDate = <InboxTask>[];
  for (final t in open) {
    final d = t.dueDate ?? '';
    if (d.isEmpty) {
      noDate.add(t);
    } else if (d == todayStr) {
      today.add(t);
    } else if (d.compareTo(todayStr) < 0) {
      overdue.add(t);
    } else {
      upcoming.add(t);
    }
  }
  int byDue(InboxTask a, InboxTask b) {
    final ad = a.dueDate ?? '', bd = b.dueDate ?? '';
    if (ad != bd) return ad.compareTo(bd);
    return (a.dueTime ?? 0) - (b.dueTime ?? 0);
  }

  overdue.sort(byDue);
  today.sort(byDue);
  upcoming.sort(byDue);
  noDate.sort((a, b) => (b.id ?? 0) - (a.id ?? 0));
  return [
    if (overdue.isNotEmpty) ('已过期', overdue),
    if (today.isNotEmpty) ('今天', today),
    if (upcoming.isNotEmpty) ('即将到来', upcoming),
    if (noDate.isNotEmpty) ('无日期', noDate),
  ];
}

/// 任务行：白圆角卡 + 优先级描边勾选框 + 加粗标题；点行打开编辑
class _TaskTile extends StatelessWidget {
  final InboxTask task;
  final Color listColor;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback? onPurge; // 只在「已完成」视图里给：永久删除

  const _TaskTile({
    required this.task,
    required this.listColor,
    required this.onToggle,
    required this.onEdit,
    this.onPurge,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pColor = task.done
        ? scheme.outlineVariant
        : prioColor(task.priority, fallback: listColor);
    final dl = task.done ? '' : dueLabel(task.dueDate, task.dueTime);
    final od = dueOverdue(task.dueDate, task.dueTime);
    final dueColor = od ? const Color(0xFFE05858) : scheme.outline;
    // 已完成视图里副标题换成「什么时候完成的」——那个列表按完成时间排序，得让人看得出来
    final sub = task.done && task.doneLabel.isNotEmpty
        ? '${task.doneLabel} 完成'
        : dl;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: onEdit,
        leading: TaskCompletionControl(
          done: task.done,
          color: pColor,
          title: task.title,
          onToggle: onToggle,
        ),
        title: Text(
          task.title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: task.done ? TextDecoration.lineThrough : null,
            color: task.done ? scheme.onSurfaceVariant : scheme.onSurface,
          ),
        ),
        subtitle: (sub.isNotEmpty || task.notes.isNotEmpty)
            ? Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        style: TextStyle(
                          fontSize: 12,
                          color: task.done ? scheme.outline : dueColor,
                          fontWeight: !task.done && od
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    if (task.notes.isNotEmpty)
                      Text(
                        task.notes,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                  ],
                ),
              )
            : null,
        trailing: onPurge != null
            ? IconButton(
                tooltip: '永久删除',
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Color(0xFFE05858),
                ),
                onPressed: onPurge,
              )
            : canPostponeDdl(task)
            ? PostponeDdlButton(task: task)
            : Icon(Icons.chevron_right, size: 20, color: scheme.outlineVariant),
      ),
    );
  }
}
