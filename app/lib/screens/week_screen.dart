import '../widgets/calendar_navigation_bar.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../auth_store.dart';
import '../models.dart';
import '../plan_bus.dart';
import '../widgets/course_details_sheet.dart';
import '../widgets/month_view.dart';
import '../widgets/week_view.dart';
import 'block_editor.dart';
import 'login_screen.dart';

class WeekScreen extends StatefulWidget {
  const WeekScreen({super.key});

  @override
  State<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends State<WeekScreen> {
  late DateTime _startDate; // 显示范围起点
  int _rangeDays = 7; // 1/3/7
  List<WeekDay> _days = [];
  int? _weekNum;
  bool _loading = true;
  String? _error;
  bool _monthView = false; // 月/周主模式
  DateTime _month = DateTime.now();
  Map<String, int> _dayMarks = {};

  @override
  void initState() {
    super.initState();
    _startDate = _mondayOf(DateTime.now());
    PlanBus.instance.revision.addListener(_onDataChanged);
    _load();
  }

  @override
  void dispose() {
    PlanBus.instance.revision.removeListener(_onDataChanged);
    super.dispose();
  }

  /// 任一面板改动数据后，任务视图(时间轴)重拉(跨面板自动同步)。
  void _onDataChanged() {
    if (mounted) _load(keepVisible: true);
  }

  DateTime _mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  String _fmt(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _todayStr() => _fmt(DateTime.now());

  Future<void> _load({bool keepVisible = false}) async {
    setState(() {
      _loading = !keepVisible || _days.isEmpty;
      _error = null;
    });
    try {
      // 月视图：拉整月 31 天，统计每天内容数
      if (_monthView) {
        final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
        final first =
            '${_month.year}-${_month.month.toString().padLeft(2, '0')}-01';
        final all = await Api.instance.range(first, daysInMonth);
        if (!mounted) return;
        setState(() {
          _dayMarks = {for (final d in all) d.date: d.items.length};
          _loading = false;
        });
        return;
      }
      // 周时间轴视图：直接用后端算好的周数(周末无课也能推出准确周数)
      final (days, weekNum) = await Api.instance.rangeWithWeek(
        _fmt(_startDate),
        _rangeDays,
      );
      if (!mounted) return;
      setState(() {
        _days = days;
        _weekNum = weekNum;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (e.message.contains('登录')) {
        await AuthStore.clear();
        Api.instance.token = null;
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
            (_) => false,
          );
        }
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('WEEK_LOAD_ERROR: $e');
      setState(() {
        _error = '网络错误: $e';
        _loading = false;
      });
    }
  }

  void _shift(int dir) {
    setState(
      () => _startDate = _startDate.add(Duration(days: dir * _rangeDays)),
    );
    _load();
  }

  void _setRange(int n) {
    setState(() {
      _rangeDays = n;
      _startDate = n >= 7 ? _mondayOf(DateTime.now()) : DateTime.now();
    });
    _load();
  }

  void _setMonthView(bool on) {
    setState(() {
      _monthView = on;
      if (on) _month = DateTime.now();
    });
    _load();
  }

  // 统一视图切换：0=月, 1=日, 3=3日, 7=周
  void _setView(int mode) {
    if (mode == 0) {
      _setMonthView(true);
      return;
    }
    if (_monthView) {
      setState(() => _monthView = false);
    }
    _setRange(mode);
  }

  // 右上角视图图标：点开下拉直接跳 日/3日/周/月(当前项打勾)，不再循环
  PopupMenuItem<int> _viewItem(int mode, String name) {
    final cur = _monthView ? 0 : _rangeDays;
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Icon(
            mode == cur ? Icons.check : Icons.circle_outlined,
            size: 18,
            color: mode == cur ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 8),
          Text(name),
        ],
      ),
    );
  }

  static String _modeLabel(int m) => switch (m) {
    0 => '月',
    1 => '日',
    3 => '3日',
    _ => '周',
  };

  void _shiftMonth(int m) {
    setState(() => _month = DateTime(_month.year, _month.month + m, 1));
    _load();
  }

  void _gotoTodayMonth() {
    setState(() => _month = DateTime.now());
    _load();
  }

  // 点击 AppBar 年份 -> 选择年份
  Future<void> _pickYear() async {
    final y = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择年份'),
        children: [
          for (var i = DateTime.now().year + 3; i >= 2020; i--)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Text(
                '$i 年',
                style: TextStyle(
                  fontSize: 16,
                  color: i == _month.year
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
    if (y != null) {
      setState(() => _month = DateTime(y, _month.month, 1));
      _load();
    }
  }

  // 点击月视图月份 -> 选择月份
  Future<void> _pickMonth() async {
    final m = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择月份'),
        children: [
          for (var i = 1; i <= 12; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Text(
                '$i 月',
                style: TextStyle(
                  fontSize: 16,
                  color: i == _month.month
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
    if (m != null) {
      setState(() => _month = DateTime(_month.year, m, 1));
      _load();
    }
  }

  // 月视图点某天 -> 进入该天单日时间轴
  void _pickDay(String date) {
    setState(() {
      _monthView = false;
      _startDate = DateTime.parse(date);
      _rangeDays = 1;
    });
    _load();
  }

  void _gotoToday() {
    if (_monthView) {
      _gotoTodayMonth();
      return;
    }
    setState(() {
      _startDate = _rangeDays >= 7 ? _mondayOf(DateTime.now()) : DateTime.now();
    });
    _load();
  }

  // AppBar 图标统一样式：紧凑、无内边距，尽量给中间标题让出显示空间
  Widget _appBarIcon({
    required Widget icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
      iconSize: 22,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    );
  }

  Future<void> _openEditor(
    String date,
    TimelineItem? item, {
    int? startMin,
    int? endMin,
  }) async {
    if (item?.type == 'class') {
      await showCourseDetails(context, item!);
      return;
    }
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BlockEditor(
          date: date,
          item: item,
          startMin: startMin,
          endMin: endMin,
        ),
      ),
    );
    if (changed == true) _load();
  }

  String _rangeLabel() {
    final end = _startDate.add(Duration(days: _rangeDays - 1));
    final a = DateFormat('M月d日').format(_startDate);
    final b = DateFormat('M月d日').format(end);
    return '$a - $b';
  }

  // 单日天：AppBar 标题就是"9月5日"+副标题"周六 · 今天"(日期只在标题出现一次，避免与大标题/表头三处重复)
  List<Widget> _dayTitle() {
    final scheme = Theme.of(context).colorScheme;
    final isToday =
        _startDate.year == DateTime.now().year &&
        _startDate.month == DateTime.now().month &&
        _startDate.day == DateTime.now().day;
    return [
      Text(
        DateFormat('M月d日').format(_startDate),
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      Text(
        _cnWeek(_startDate.weekday) + (isToday ? ' · 今天' : ''),
        style: TextStyle(fontSize: 11, color: scheme.outline),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isMonth = _monthView;
    return Scaffold(
      appBar: !isMonth
          ? CalendarNavigationBar(
              title: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _rangeDays == 1
                      ? _dayTitle()
                      : [
                          Text(
                            '第${_weekNum ?? '?'}周',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _rangeLabel(),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                ),
              ),
              viewMenu: PopupMenuButton<int>(
                tooltip: '切换视图',
                icon: _viewIcon(
                  _rangeDays,
                  Theme.of(context).colorScheme.onSurface,
                ),
                onSelected: _setView,
                itemBuilder: (_) => [
                  _viewItem(1, '日'),
                  _viewItem(3, '3日'),
                  _viewItem(7, '周'),
                  _viewItem(0, '月'),
                ],
              ),
              onPrevious: () => _shift(-1),
              onNext: () => _shift(1),
              onToday: _gotoToday,
            )
          : AppBar(
              title: GestureDetector(
                onTap: _pickYear,
                child: Text(
                  '${_month.year}年',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              leadingWidth: 12,
              actions: [
                // 右上角：视图图标，点开下拉直接跳 日/3日/周/月(当前项打勾)
                PopupMenuButton<int>(
                  tooltip: '${_modeLabel(_monthView ? 0 : _rangeDays)}视图',
                  icon: _viewIcon(
                    _monthView ? 0 : _rangeDays,
                    Theme.of(context).colorScheme.onSurface,
                  ),
                  iconSize: 22,
                  padding: EdgeInsets.zero,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  onSelected: _setView,
                  itemBuilder: (_) => [
                    _viewItem(1, '日'),
                    _viewItem(3, '3日'),
                    _viewItem(7, '周'),
                    _viewItem(0, '月'),
                  ],
                ),
                _appBarIcon(
                  icon: const Icon(Icons.today_outlined),
                  tooltip: '回到今天',
                  onPressed: _gotoToday,
                ),
              ],
            ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(_todayStr(), null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_monthView) {
      return Column(
        children: [
          Expanded(
            child: MonthView(
              month: _month,
              dayMarks: _dayMarks,
              todayStr: _todayStr(),
              onPickDay: _pickDay,
              onPrev: () => _shiftMonth(-1),
              onNext: () => _shiftMonth(1),
              onToday: _gotoTodayMonth,
              onPickMonth: _pickMonth,
            ),
          ),
        ],
      );
    }
    // 单日且无任何安排时显示空态(图5风)
    final isEmptyDay =
        _rangeDays == 1 && _days.isNotEmpty && _days.first.items.isEmpty;
    final isTodayEmpty = isEmptyDay && _days.first.date == _todayStr();

    // 单日：保留连续 24h 时间轴(每天每小时干什么)，全宽更清晰。
    // 日期只在 AppBar 呈现一次；空态作 top 并入时间轴竖向滚动(上滑滚出视口)。
    // 关掉周几表头(showDayHeader:false)，避免"9月5日"在大标题/表头/AppBar 三处重复。
    if (_rangeDays == 1) {
      return WeekView(
        days: _days,
        todayStr: _todayStr(),
        hourHeight: 120,
        showDayHeader: false,
        onTapEmpty: (date, s, e) =>
            _openEditor(date, null, startMin: s, endMin: e),
        onTapItem: (date, item) => _openEditor(date, item),
        onMoveItem: (date, item, start, end) => Api.instance.updateBlock(
          item.id!,
          date: date,
          startMin: start,
          endMin: end,
        ),
        top: isTodayEmpty ? const _EmptyState() : null,
      );
    }
    // 3日/周：与单日一致的可滚动连续 7:00-24:00 时间轴(不裁时间、不用大节网格)。
    // 左边只留小时刻度，顶部周几表头；按天数压行高：7天俯瞰整周、3天略放大。
    final hourHeight = _rangeDays == 7 ? 46.0 : 78.0;
    return Column(
      children: [
        Expanded(
          child: WeekView(
            days: _days,
            todayStr: _todayStr(),
            hourHeight: hourHeight,
            startHour: 7,
            onTapEmpty: (date, s, e) =>
                _openEditor(date, null, startMin: s, endMin: e),
            onTapItem: (date, item) => _openEditor(date, item),
            onMoveItem: (date, item, start, end) => Api.instance.updateBlock(
              item.id!,
              date: date,
              startMin: start,
              endMin: end,
            ),
          ),
        ),
      ],
    );
  }
}

/// 空态：紧凑单行提示(小叶子+一句话)，随时间轴上滑滚出视图，不占死大块空间。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('🍃', style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          Text(
            '今天没有安排，放松一下吧',
            style: TextStyle(fontSize: 13, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

String _cnWeek(int wd) =>
    const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][wd.clamp(1, 7)];

/// 当前视图图标：月=日历, 日=1点, 3日=3点, 周=上2下2(4点小周历格子)。
/// 只返回图标本身(不带容器)，用作 AppBar 右上角单图标。
Widget _viewIcon(int mode, Color color) {
  if (mode == 0) {
    return Icon(Icons.calendar_month_outlined, size: 22, color: color);
  }
  if (mode == 7) {
    return _iconDots(const [
      [1, 1],
      [1, 1],
    ], color: color);
  }
  // 1 或 3：一行
  return _iconDots([List.filled(mode, 1)], color: color);
}

Widget _iconDots(List<List<int>> grid, {required Color color}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final row in grid) ...[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (final _ in row) _iconDot(color)],
        ),
        if (grid.indexOf(row) != grid.length - 1) const SizedBox(height: 2),
      ],
    ],
  );
}

Widget _iconDot(Color color) => Container(
  width: 5,
  height: 5,
  margin: const EdgeInsets.symmetric(horizontal: 1),
  decoration: BoxDecoration(shape: BoxShape.circle, color: color),
);
