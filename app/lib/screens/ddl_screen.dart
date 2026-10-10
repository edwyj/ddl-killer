import 'package:flutter/material.dart';
import 'package:lunar/lunar.dart';

import '../api.dart';
import '../models.dart';
import '../plan_bus.dart';
import '../widgets/task_editor.dart';
import '../widgets/postpone_ddl.dart';
import '../widgets/task_completion_control.dart';
import '../ddl_postponement.dart';

/// DDL 板块：日历(有 DDL 打点) + 选中日当天 DDL 清单。
/// 日历和清单共用滚动：先收起月历到选中周，再滚动任务；回到清单顶部后再展开月历。
/// 只汇总"将至截止日"(距今天 ≤ ddlLookaheadDays 或已过期)的任务；远期/无日期算清单项。
class DdlScreen extends StatefulWidget {
  const DdlScreen({super.key, this.now});
  final DateTime Function()? now;

  @override
  State<DdlScreen> createState() => _DdlScreenState();
}

class _DdlScreenState extends State<DdlScreen> {
  /// 每行(每周)固定高度，不再随缩放收拢；遮罩是靠整体平移+裁切实现的。
  static const double _rowH = 48.0;
  static const double _headerH = 26.0; // 周几表头高度
  static const double _grabPad = 8.0; // 日历与任务之间留少量间距
  final Map<String, String> _festCache = {}; // yyyy-MM-dd -> 节日/节气 文案(懒计算缓存)

  List<InboxTask> _tasks = [];
  bool _loading = true;
  String? _error;
  late DateTime _month; // 显示的月
  String _selected = ''; // 选中日 yyyy-MM-dd
  String _todayStr = '';
  bool _doneCollapsed = true;
  final ScrollController _scroll = ScrollController();
  bool _hasData = false;
  int _loadRevision = 0;
  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _todayStr = _dstr(_now);
    _month = DateTime(_now.year, _now.month, 1);
    _selected = _todayStr;
    PlanBus.instance.revision.addListener(_onDataChanged);
    _load();
  }

  @override
  void dispose() {
    PlanBus.instance.revision.removeListener(_onDataChanged);
    _loadRevision++;
    _scroll.dispose();
    super.dispose();
  }

  /// 任一面板改动数据后，DDL 页也跟着重拉(跨面板自动同步)。下拉刷新也走 _load。
  void _onDataChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final revision = ++_loadRevision;
    setState(() {
      _loading = !_hasData;
      _error = null;
    });
    try {
      final tasks = await Api.instance.inbox();
      if (mounted && revision == _loadRevision) {
        setState(() {
          _tasks = tasks;
          _hasData = true;
          _loading = false;
        });
      }
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

  static String _dstr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 距今天天数(负数=已过期)。
  static int _diffDays(String dateStr, DateTime now) {
    final d = DateTime.tryParse(dateStr);
    if (d == null) return 99999;
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(d.year, d.month, d.day);
    return due.difference(today).inDays;
  }

  bool _isDdl(InboxTask t) {
    if (t.dueDate == null || t.dueDate!.isEmpty) return false;
    return _diffDays(t.dueDate!, _now) <= ddlLookaheadDays;
  }

  /// 取某天的节日/节气文案(优先传统农历节日 > 公历节日 > 节气 > 其他)，带缓存避免每帧重算。
  String? _festivalFor(DateTime d) {
    final key = _dstr(d);
    final hit = _festCache[key];
    if (hit != null) return hit.isEmpty ? null : hit;
    String? label;
    try {
      final s = Solar.fromDate(d);
      final l = s.getLunar();
      final trad = l.getFestivals();
      if (trad.isNotEmpty) {
        label = trad.first;
      } else {
        final sol = s.getFestivals();
        if (sol.isNotEmpty) {
          label = sol.first;
        } else {
          final jq = l.getJieQi();
          if (jq.isNotEmpty) {
            label = jq;
          } else {
            final other = l.getOtherFestivals();
            if (other.isNotEmpty) label = other.first;
          }
        }
      }
    } catch (_) {
      label = null; // 个别阳历边界算不出就静默，不漏日历
    }
    _festCache[key] = label ?? '';
    return label;
  }

  double get _collapseExtent => (_geom(0).numWeeks - 1) * _rowH;
  double get _progress => !_scroll.hasClients
      ? 0
      : (_scroll.offset / _collapseExtent).clamp(0.0, 1.0);

  /// 当前月/缩放下的网格几何(渲染与点按共用同一套，避免命中偏移)。
  ({double et, double clipH, double selTop, int lead, int numWeeks, int selRow})
  _geom(double progress) {
    final et = progress;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = DateTime(_month.year, _month.month, 1).weekday - 1;
    final numWeeks = ((lead + daysInMonth + 6) ~/ 7);
    int selRow = -1;
    final sel = DateTime.tryParse(_selected);
    if (sel != null && sel.year == _month.year && sel.month == _month.month) {
      selRow = (lead + (sel.day - 1)) ~/ 7;
    }
    final fullH = numWeeks * _rowH;
    final selTop = selRow >= 0 ? selRow * _rowH : 0.0;
    final clipH = fullH - (fullH - _rowH) * et; // 窗口高度 整月 → 单周
    return (
      et: et,
      clipH: clipH,
      selTop: selTop,
      lead: lead,
      numWeeks: numWeeks,
      selRow: selRow,
    );
  }

  void _toggleZoom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _progress < 0.5 ? _collapseExtent : 0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _changeCalendar(VoidCallback change) {
    final progress = _progress;
    setState(change);
    if (_scroll.hasClients) _scroll.jumpTo(progress * _collapseExtent);
  }

  // ---- 月切换(左右滑) ----
  void _onMonthSwipe(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v < -120) {
      _changeCalendar(
        () => _month = DateTime(_month.year, _month.month + 1, 1),
      );
    } else if (v > 120) {
      _changeCalendar(
        () => _month = DateTime(_month.year, _month.month - 1, 1),
      );
    }
  }

  void _onToday() {
    _changeCalendar(() {
      _todayStr = _dstr(_now);
      _month = DateTime(_now.year, _now.month, 1);
      _selected = _todayStr;
    });
  }

  void _pick(DateTime d) {
    _changeCalendar(() {
      _month = DateTime(d.year, d.month, 1);
      _selected = _dstr(d);
    });
  }

  Future<void> _addForSelected() async {
    final changed = await showTaskEditor(context, initialDueDate: _selected);
    if (changed == true) _load();
  }

  Future<void> _toggle(InboxTask t) async {
    try {
      await Api.instance.updateInbox(t.id!, done: !t.done);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _edit(InboxTask t) async {
    final changed = await showTaskEditor(context, task: t);
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && !_hasData) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, viewport) => RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _DdlCalendarHeader(
                    minimum: kToolbarHeight + _headerH + _rowH + _grabPad,
                    maximum:
                        kToolbarHeight +
                        _headerH +
                        _geom(0).numWeeks * _rowH +
                        _grabPad,
                    builder: (progress) => Material(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Column(
                        children: [
                          SizedBox(
                            height: kToolbarHeight,
                            child: _calendarBar(),
                          ),
                          _gridZone(scheme, progress),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          (viewport.maxHeight -
                                  kToolbarHeight -
                                  _headerH -
                                  _rowH -
                                  _grabPad)
                              .clamp(0.0, double.infinity),
                    ),
                    child: _dayList(scheme),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addForSelected,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _calendarBar() => AppBar(
    primary: false,
    automaticallyImplyLeading: false,
    centerTitle: false,
    title: Text(
      '${_month.year}年 ${_month.month}月',
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
    ),
    actions: [
      TextButton(onPressed: _onToday, child: const Text('今天')),
      const SizedBox(width: 4),
      AnimatedBuilder(
        animation: _scroll,
        builder: (_, __) => IconButton(
          icon: const Icon(Icons.grid_view),
          tooltip: _progress < 0.5 ? '切到周视图' : '切到月视图',
          onPressed: _toggleZoom,
        ),
      ),
      const SizedBox(width: 4),
    ],
  );

  // ---- 周几表头（常驻，不随缩放变化） ----
  Widget _weekdayHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
            Expanded(
              child: Center(
                child: Text(
                  w,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Vertical movement belongs to the common scroll view; this detector only
  /// handles calendar taps and horizontal month navigation.
  Widget _gridZone(ColorScheme scheme, double progress) {
    final g = _geom(progress);
    final ddl = _tasks.where(_isDdl).toList();
    final ddlByDate = _groupByDate(ddl);

    final rows = <Widget>[];
    for (var w = 0; w < g.numWeeks; w++) {
      final cells = <Widget>[];
      for (var c = 0; c < 7; c++) {
        final dayNum = w * 7 + c - g.lead + 1;
        final d = DateTime(_month.year, _month.month, dayNum); // 越界自动归一化到邻月
        final inside = d.month == _month.month && d.year == _month.year;
        final ds = _dstr(d);
        cells.add(
          Expanded(
            child: _DayCell(
              dayNum: d.day,
              faded: !inside,
              isToday: ds == _todayStr,
              isSelected: ds == _selected,
              hasContent: (ddlByDate[ds] ?? 0) > 0,
              festival: _festivalFor(d),
            ),
          ),
        );
      }
      rows.add(
        SizedBox(
          height: _rowH,
          child: Row(children: cells),
        ),
      );
    }

    final zoneH = _headerH + g.clipH + _grabPad;
    return LayoutBuilder(
      builder: (context, bounds) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _onMonthSwipe,
        onTapUp: (details) =>
            _onCalendarTap(details, progress, bounds.maxWidth),
        child: SizedBox(
          key: const ValueKey('ddl-calendar'),
          height: zoneH,
          width: double.infinity,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _weekdayHeader(scheme),
              ),
              Positioned(
                top: _headerH,
                left: 0,
                right: 0,
                child: ClipRect(
                  child: SizedBox(
                    height: g.clipH,
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: g.numWeeks * _rowH,
                      maxHeight: g.numWeeks * _rowH,
                      child: Transform.translate(
                        offset: Offset(0, -g.selTop * g.et),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Column(children: rows),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 按点击位置换算成日期(同一 GestureDetector 统一处理 tap, 与拖拽互斥, 不会拖的同时选日)。
  void _onCalendarTap(TapUpDetails d, double progress, double width) {
    final day = _dayFromTap(d.localPosition, progress, width);
    if (day != null) _pick(day);
  }

  DateTime? _dayFromTap(Offset local, double progress, double width) {
    final g = _geom(progress);
    final gridY = local.dy - _headerH; // 换算到网格顶部(下方空带/表头都不算选日)
    if (gridY < 0 || gridY > g.clipH) return null;
    final contentY = gridY + g.selTop * g.et; // 内容被上移 -selTop*et，坐标还原
    var row = (contentY / _rowH).floor();
    if (row < 0 || row > g.numWeeks - 1) return null;
    final cellW = (width - 16) / 7;
    var col = ((local.dx - 8) / cellW).floor();
    if (col < 0) col = 0;
    if (col > 6) col = 6;
    final dayNum = row * 7 + col - g.lead + 1;
    return DateTime(_month.year, _month.month, dayNum);
  }

  Map<String, int> _groupByDate(List<InboxTask> ddl) {
    final m = <String, int>{};
    for (final t in ddl) {
      final d = t.dueDate!;
      m[d] = (m[d] ?? 0) + 1;
    }
    return m;
  }

  /// 选中日的 DDL 行 + 空日状态 + 已完成折叠。
  Widget _dayList(ColorScheme scheme) {
    final ddl = _tasks.where(_isDdl).toList();
    final open = ddl.where((t) => t.dueDate == _selected && !t.done).toList()
      ..sort((a, b) {
        final at = a.dueTime ?? 1440, bt = b.dueTime ?? 1440;
        if (at != bt) return at - bt;
        return (a.id ?? 0) - (b.id ?? 0);
      });
    final done = ddl.where((t) => t.dueDate == _selected && t.done).toList();

    final Widget list;
    if (open.isEmpty && done.isEmpty) {
      list = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
            child: Column(
              children: [
                Icon(Icons.event_available, size: 56, color: scheme.outline),
                const SizedBox(height: 12),
                Text(
                  '这一天没有到期的 DDL 🎀',
                  style: TextStyle(
                    color: scheme.outline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '按自己的节奏，把想做的事慢慢安排好。',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      list = Column(
        children: [
          for (final t in open)
            _DdlTile(
              task: t,
              now: _now,
              onToggle: () => _toggle(t),
              onEdit: () => _edit(t),
            ),
          if (done.isNotEmpty) ...[
            ListTile(
              onTap: () => setState(() => _doneCollapsed = !_doneCollapsed),
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
              trailing: Icon(
                _doneCollapsed
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_up,
                color: scheme.outline,
              ),
            ),
            if (!_doneCollapsed)
              for (final t in done)
                _DdlTile(
                  task: t,
                  now: _now,
                  onToggle: () => _toggle(t),
                  onEdit: () => _edit(t),
                ),
          ],
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 96),
      child: list,
    );
  }
}

class _DdlCalendarHeader extends SliverPersistentHeaderDelegate {
  const _DdlCalendarHeader({
    required this.minimum,
    required this.maximum,
    required this.builder,
  });
  final double minimum, maximum;
  final Widget Function(double) builder;
  @override
  double get minExtent => minimum;
  @override
  double get maxExtent => maximum;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ClipRect(
    child: builder((shrinkOffset / (maximum - minimum)).clamp(0.0, 1.0)),
  );
  @override
  bool shouldRebuild(covariant _DdlCalendarHeader oldDelegate) =>
      oldDelegate.minimum != minimum ||
      oldDelegate.maximum != maximum ||
      oldDelegate.builder != builder;
}

class _DayCell extends StatelessWidget {
  final int dayNum;
  final bool isToday;
  final bool isSelected;
  final bool hasContent;
  final bool faded;
  final String? festival;

  const _DayCell({
    required this.dayNum,
    this.isToday = false,
    this.isSelected = false,
    this.hasContent = false,
    this.faded = false,
    this.festival,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = faded
        ? scheme.outline.withValues(alpha: 0.4)
        : scheme.onSurface;
    const sz = 34.0; // 固定，不做缩放(遮罩方案，行高/圆圈都不动)
    final showFestival = festival != null && festival!.isNotEmpty;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: sz,
            height: sz,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isToday
                  ? scheme.primary
                  : isSelected
                  ? scheme.primary.withValues(alpha: 0.15)
                  : null,
              border: isSelected && !isToday
                  ? Border.all(color: scheme.primary, width: 1.5)
                  : null,
            ),
            child: Text(
              '$dayNum',
              style: TextStyle(
                fontSize: 14.5,
                color: isToday ? Colors.white : base,
                fontWeight: isToday || isSelected
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            height: 13,
            child: showFestival
                // 节日名长短差得很远：「元旦」两个字，「全国中小学生安全教育日」十一个字。
                // 槽位固定 13px 只够一行(9.5px)，长名字换到第二行就被裁掉半截。
                // 现在给它整格宽 + 最多两行，再整体缩放进槽位：
                // 短名字仍是一行 9.5px 原样，长名字自动变两行小字 —— 宁可小，不可断。
                // 节日名长短差得很远：「元旦」两个字，「全国中小学生安全教育日」十一个字。
                // 槽位只有 13px(够一行 9.5px)，长名字一换行就被 SizedBox 裁掉下半截。
                // 这里钉死一行、整块等比缩进格子：短名字原样，长名字变小，但永远不漏字。
                // (试过放两行，但两行只能摊到 13px ⇒ 每行 6.5px，比一行被缩还难认，故弃。)
                ? Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        festival!,
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: scheme.primary,
                          height: 1,
                        ),
                      ),
                    ),
                  )
                : hasContent
                ? Center(
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: isToday ? Colors.white : scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// DDL 任务行。
class _DdlTile extends StatelessWidget {
  final InboxTask task;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final DateTime now;

  const _DdlTile({
    required this.task,
    required this.now,
    required this.onToggle,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pColor = task.done
        ? scheme.outlineVariant
        : prioColor(task.priority, fallback: scheme.primary);
    final cd = task.done
        ? ''
        : ddlCountdown(task.dueDate, task.dueTime, now: now);
    final od = dueOverdue(task.dueDate, task.dueTime, now: now);
    final dueColor = od ? const Color(0xFFE05858) : scheme.outline;
    return Card(
      key: ValueKey('ddl-task-${task.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
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
            color: task.done ? scheme.outline : null,
          ),
        ),
        subtitle: cd.isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  cd,
                  style: TextStyle(
                    fontSize: 12,
                    color: dueColor,
                    fontWeight: od ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              )
            : null,
        trailing: canPostponeDdl(task, now: now)
            ? PostponeDdlButton(task: task)
            : Icon(Icons.chevron_right, size: 20, color: scheme.outlineVariant),
      ),
    );
  }
}
