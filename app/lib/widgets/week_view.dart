import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, GestureBinding, PointerScrollEvent;

import '../models.dart';
import 'timeline_layout.dart';
import 'layout_scroll_controller.dart';

/// TickTick 风格周视图：横向周一~周日 7 列 + 纵向 00:00-24:00。
/// 块按 start_min/end_min 在对应列的垂直位置放置，按颜色区分课程/任务。
class WeekView extends StatefulWidget {
  final List<WeekDay> days; // 7 天
  final String todayStr; // 今天的日期(用于高亮今天列)
  final double hourHeight;
  final double startHour; // 时间轴起始(小时)，凌晨睡前不显示
  final void Function(String date, int startMin, int endMin) onTapEmpty;
  final void Function(String date, TimelineItem item) onTapItem;

  final Future<void> Function(
    String date,
    TimelineItem item,
    int start,
    int end,
  )?
  onMoveItem;

  /// 需与时间轴一起滚动的顶部内容(如空态/日期大标题)，放在网格上方、随整块竖向滚动。
  final Widget? top;

  /// 是否显示顶部"周几+日期"表头。单日视图日期已在 AppBar 呈现，表头属重复信息可关掉。
  final bool showDayHeader;

  const WeekView({
    super.key,
    required this.days,
    required this.todayStr,
    required this.onTapEmpty,
    required this.onTapItem,
    this.onMoveItem,
    this.hourHeight = 56,
    this.startHour = 7,
    this.top,
    this.showDayHeader = true,
  });

  @override
  State<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<WeekView> {
  List<WeekDay> get days => widget.days;
  String get todayStr => widget.todayStr;
  double _heightAtZoom(double zoom) => (widget.hourHeight * zoom).clamp(
    widget.hourHeight < 32 ? widget.hourHeight : 32.0,
    widget.hourHeight > 120 ? widget.hourHeight : 120.0,
  );
  double get hourHeight => _heightAtZoom(_zoom);
  double get startHour => widget.startHour;
  Widget? get top => widget.top;
  bool get showDayHeader => widget.showDayHeader;
  void Function(String, int, int) get onTapEmpty => widget.onTapEmpty;
  void Function(String, TimelineItem) get onTapItem => widget.onTapItem;
  final _viewportKey = GlobalKey();
  final _columns = <String, GlobalKey>{};
  final _vertical = LayoutScrollController();
  final _horizontal = LayoutScrollController();
  double _zoom = 1, _gestureZoom = 1, _gestureScale = 1;
  double _baseDayWidth = 104;
  Offset _gestureAnchor = Offset.zero;
  bool _pinching = false;
  int _pointerCount = 0;
  Timer? _ticker;
  TimelineItem? _dragItem;
  String? _sourceDate, _targetDate;
  int? _targetStart;
  double _grabMinutes = 0;
  Offset? _pointer;
  bool _saving = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  RenderBox? _box(GlobalKey key) =>
      key.currentContext?.findRenderObject() as RenderBox?;

  void _startDrag(String date, TimelineItem item, Offset pointer) {
    if (_saving || widget.onMoveItem == null) return;
    final box = _box(_columns[date]!);
    if (box == null) return;
    _grabMinutes =
        startHour * 60 +
        box.globalToLocal(pointer).dy / hourHeight * 60 -
        item.startMin;
    setState(() {
      _dragItem = item;
      _sourceDate = date;
      _targetDate = date;
      _targetStart = item.startMin;
      _pointer = pointer;
    });
    _ticker = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _autoScroll(),
    );
  }

  void _autoScroll() {
    if (_dragItem == null || _pointer == null) return;
    final box = _box(_viewportKey);
    if (box == null) return;
    final p = box.globalToLocal(_pointer!);
    if (p.dx < 0 ||
        p.dx > box.size.width ||
        p.dy < 0 ||
        p.dy > box.size.height) {
      return;
    }
    bool shift(
      ScrollController controller,
      double value,
      double low,
      double high,
    ) {
      if (!controller.hasClients) return false;
      final delta = value < low + 40 ? -10.0 : (value > high - 40 ? 10.0 : 0.0);
      final position = controller.position;
      final next = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next == position.pixels) return false;
      controller.jumpTo(next);
      return true;
    }

    final vertical = shift(_vertical, p.dy, 0, box.size.height);
    final horizontal = shift(_horizontal, p.dx, 34, box.size.width);
    if (vertical || horizontal) _updateDrag(_pointer!);
  }

  void _updateDrag(Offset pointer) {
    final item = _dragItem;
    if (item == null) return;
    _pointer = pointer;
    String? date;
    int? minute;
    final viewport = _box(_viewportKey);
    if (viewport != null &&
        (Offset.zero & viewport.size).contains(
          viewport.globalToLocal(pointer),
        )) {
      for (final day in days) {
        final box = _box(_columns[day.date]!);
        if (box == null) continue;
        final local = box.globalToLocal(pointer);
        if (!(Offset.zero & box.size).contains(local)) continue;
        final duration = item.endMin - item.startMin;
        final maxStart = ((1440 - duration) / 15).floor() * 15;
        if (duration <= 0 || maxStart < 0) continue;
        final raw = startHour * 60 + local.dy / hourHeight * 60 - _grabMinutes;
        minute = ((raw / 15).round() * 15).clamp(0, maxStart);
        date = day.date;
        break;
      }
    }
    setState(() {
      _targetDate = date;
      _targetStart = minute;
    });
  }

  Future<void> _endDrag({bool cancel = false}) async {
    _ticker?.cancel();
    final item = _dragItem, date = _targetDate, start = _targetStart;
    final changed =
        item != null &&
        date != null &&
        start != null &&
        (date != _sourceDate || start != item.startMin);
    setState(() {
      _dragItem = null;
      _targetDate = null;
      _targetStart = null;
      _pointer = null;
    });
    if (cancel || !changed) return;
    setState(() => _saving = true);
    try {
      await widget.onMoveItem!(
        date,
        item,
        start,
        start + item.endMin - item.startMin,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('调整时间失败，已保留原排期，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dragHandle(String date, TimelineItem item, Widget child) {
    if (item.type != 'task' || item.id == null || widget.onMoveItem == null) {
      return child;
    }
    return Listener(
      onPointerCancel: (_) {
        if (_dragItem != null) _endDrag(cancel: true);
      },
      child: MouseRegion(
        cursor: _saving ? SystemMouseCursors.wait : SystemMouseCursors.grab,
        child: GestureDetector(
          supportedDevices: const {PointerDeviceKind.mouse},
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (d) => _startDrag(date, item, d.globalPosition),
          onPanUpdate: (d) => _updateDrag(d.globalPosition),
          onPanEnd: (_) => _endDrag(),
          onPanCancel: () => _endDrag(cancel: true),
          child: GestureDetector(
            supportedDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
            onLongPressStart: (d) => _startDrag(date, item, d.globalPosition),
            onLongPressMoveUpdate: (d) => _updateDrag(d.globalPosition),
            onLongPressEnd: (_) => _endDrag(),
            onLongPressCancel: () {
              if (_dragItem != null) _endDrag(cancel: true);
            },
            child: _dragItem?.id == item.id
                ? Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Opacity(opacity: 0.12, child: child),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            key: const ValueKey('drag-origin-placeholder'),
                            painter: _DashedOutlinePainter(
                              color:
                                  (_parseHex(item.color) ??
                                          Theme.of(context).colorScheme.primary)
                                      .withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : child,
          ),
        ),
      ),
    );
  }

  double get _startMin => startHour * 60;
  double _y(int min) => (min - _startMin) / 60 * hourHeight;

  @override
  Widget build(BuildContext context) {
    const labelW = 34.0;
    const headerH = 54.0; // 表头与刻度垫高一致，并容纳系统默认字体行高。
    final layoutHourHeight = hourHeight;
    final total = (24 - startHour) * layoutHourHeight;
    final lineColor = Theme.of(context).dividerColor.withValues(alpha: 0.4);
    final labelStyle = Theme.of(context).textTheme.bodySmall!
        .copyWith(fontSize: 10, color: Theme.of(context).colorScheme.outline);

    return SizedBox(
      key: _viewportKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportW = constraints.maxWidth - labelW;
          final mobile = constraints.maxWidth < 600;
          final defaultDays = mobile ? days.length.clamp(1, 3) : days.length;
          final mostDays = mobile ? days.length.clamp(1, 4) : days.length;
          _baseDayWidth = viewportW / defaultDays;
          final minZoom = days.length == 1 ? 0.65 : defaultDays / mostDays;
          final maxZoom = days.length == 1 ? 2.0 : defaultDays.toDouble();
          final layoutZoom = _zoom.clamp(minZoom, maxZoom);
          final dayW = (_baseDayWidth * layoutZoom).clamp(
            viewportW / mostDays,
            viewportW,
          );
          final contentW = dayW * days.length;
          final actualDayW = contentW / days.length;
          Widget timeScale() => SizedBox(
            width: labelW,
            height: total + 4,
            child: Stack(
              children: [
                for (int h = startHour.round(); h <= 24; h++)
                  Positioned(
                    top: (_y(h * 60) - 7).clamp(0.0, total),
                    left: 0,
                    right: 0,
                    child: Text(
                      h == 24 ? '24' : '$h:00',
                      style: labelStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
              ],
            ),
          );
          Widget dayCols() => SizedBox(
            width: contentW,
            child: Row(
              children: [
                for (var i = 0; i < days.length; i++)
                  SizedBox(width: actualDayW, child: _dayCol(i, lineColor)),
              ],
            ),
          );
          void shift(ScrollController controller, double delta) {
            if (!controller.hasClients) return;
            final p = controller.position;
            controller.jumpTo(
              (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent),
            );
          }

          void move(Offset delta) {
            shift(_horizontal, -delta.dx);
            shift(_vertical, -delta.dy);
          }

          void idle() {
            for (final c in [_horizontal, _vertical]) {
              if (c.hasClients) {
                (c.position as ScrollPositionWithSingleContext).goIdle();
              }
            }
          }

          Widget pinnedHeader() => SizedBox(
            key: const ValueKey('week-pinned-header'),
            height: headerH,
            child: Row(
              children: [
                const SizedBox(width: labelW),
                Expanded(
                  child: Flow(
                    delegate: _WeekHeaderFlow(_horizontal, contentW, headerH),
                    children: [
                      _DayHeader(
                        days: days,
                        todayStr: todayStr,
                        dayW: actualDayW,
                        scrollable: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          return Listener(
            onPointerDown: (_) {
              _pointerCount++;
            },
            onPointerUp: (_) {
              _pointerCount = (_pointerCount - 1).clamp(0, 20);
            },
            onPointerCancel: (_) {
              _pointerCount = (_pointerCount - 1).clamp(0, 20);
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                GestureBinding.instance.pointerSignalResolver.register(
                  event,
                  (_) => move(-event.scrollDelta),
                );
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              supportedDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.trackpad,
              },
              onScaleStart: (_) {
                idle();
                _pinching = false;
              },
              onScaleUpdate: (event) {
                if (_dragItem != null) return;
                if (_pointerCount < 2 && event.pointerCount < 2) {
                  if (!_pinching) move(event.focalPointDelta);
                  return;
                }
                if (!_pinching) {
                  _pinching = true;
                  _gestureZoom = _zoom;
                  _gestureScale = event.scale;
                  final focal = event.localFocalPoint;
                  final anchorX = (focal.dx - labelW).clamp(0.0, viewportW);
                  final anchorY = (focal.dy - (showDayHeader ? headerH : 0))
                      .clamp(0.0, constraints.maxHeight);
                  _gestureAnchor = Offset(
                    (_horizontal.displayOffset + anchorX) / actualDayW,
                    (_vertical.displayOffset + anchorY) / hourHeight,
                  );
                }
                final next = (_gestureZoom * event.scale / _gestureScale).clamp(
                  minZoom,
                  maxZoom,
                );
                final focal = event.localFocalPoint;
                final anchorX = (focal.dx - labelW).clamp(0.0, viewportW);
                final anchorY = (focal.dy - (showDayHeader ? headerH : 0))
                    .clamp(0.0, constraints.maxHeight);
                final newDayW = (_baseDayWidth * next).clamp(
                  viewportW / mostDays,
                  viewportW,
                );
                final newHourH = _heightAtZoom(next);
                final horizontalReflow = (newDayW - actualDayW).abs() > 0.0001;
                final verticalReflow =
                    (newHourH - layoutHourHeight).abs() > 0.0001;
                final newTotal = (24 - startHour) * newHourH + 4;
                final gridH =
                    constraints.maxHeight - (showDayHeader ? headerH : 0);
                setState(() {
                  _zoom = next;
                  _horizontal.anchorAt(
                    (_gestureAnchor.dx * newDayW - anchorX).clamp(
                      0.0,
                      (newDayW * days.length - viewportW).clamp(
                        0.0,
                        double.infinity,
                      ),
                    ),
                    reflow: horizontalReflow,
                  );
                  _vertical.anchorAt(
                    (_gestureAnchor.dy * newHourH - anchorY).clamp(
                      0.0,
                      (newTotal - gridH).clamp(0.0, double.infinity),
                    ),
                    reflow: verticalReflow,
                  );
                });
              },
              onScaleEnd: (event) {
                if (!_pinching) {
                  if (_horizontal.hasClients) {
                    (_horizontal.position as ScrollPositionWithSingleContext)
                        .goBallistic(-event.velocity.pixelsPerSecond.dx);
                  }
                  if (_vertical.hasClients) {
                    (_vertical.position as ScrollPositionWithSingleContext)
                        .goBallistic(-event.velocity.pixelsPerSecond.dy);
                  }
                }
                _pinching = false;
              },
              child: Column(
                children: [
                  if (showDayHeader)
                    Tooltip(
                      message: '双指调整视图，双击日期栏恢复默认大小',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: () => setState(() => _zoom = 1),
                        child: pinnedHeader(),
                      ),
                    ),
                  Expanded(
                    child: Scrollbar(
                      controller: _vertical,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _vertical,
                        physics: const NeverScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            timeScale(),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                controller: _horizontal,
                                physics: const NeverScrollableScrollPhysics(
                                  parent: ClampingScrollPhysics(),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (top != null) top!,
                                    SizedBox(
                                      height: total + 4,
                                      child: dayCols(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _dayCol(int i, Color lineColor) {
    final fontScale = widget.hourHeight >= 100
        ? 1.4
        : (widget.hourHeight >= 75 ? 1.2 : 1.0);
    return _DayColumn(
      key: _columns.putIfAbsent(days[i].date, () => GlobalKey()),
      wrapItem: (item, child) => _dragHandle(days[i].date, item, child),
      previewItem: _targetDate == days[i].date ? _dragItem : null,
      previewStart: _targetStart,
      day: days[i],
      isToday: days[i].date == todayStr,
      hourHeight: hourHeight,
      startMin: _startMin,
      fontScale: fontScale,
      maxColumns: days.length == 1 ? 3 : 2,
      lineColor: lineColor,
      onTapEmpty: onTapEmpty,
      onTapItem: onTapItem,
    );
  }
}

/// Reads the body's final offset during paint, after layout corrections and
/// edge clamping. A build-time Transform can otherwise retain the old offset.
class _WeekHeaderFlow extends FlowDelegate {
  _WeekHeaderFlow(this.controller, this.width, this.height)
    : super(repaint: controller);
  final ScrollController controller;
  final double width, height;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints.tight(Size(width, height));

  @override
  void paintChildren(FlowPaintingContext context) {
    final offset = controller.hasClients ? controller.offset : 0.0;
    context.paintChild(0, transform: Matrix4.translationValues(-offset, 0, 0));
  }

  @override
  bool shouldRepaint(_WeekHeaderFlow oldDelegate) =>
      controller != oldDelegate.controller ||
      width != oldDelegate.width ||
      height != oldDelegate.height;

  @override
  bool shouldRelayout(_WeekHeaderFlow oldDelegate) =>
      width != oldDelegate.width || height != oldDelegate.height;
}

class _DayColumn extends StatelessWidget {
  final Widget Function(TimelineItem, Widget) wrapItem;
  final TimelineItem? previewItem;
  final int? previewStart;
  final WeekDay? day;
  final bool isToday;
  final double hourHeight;
  final double startMin;
  final double fontScale;
  final int maxColumns;
  final Color lineColor;
  final void Function(String, int, int) onTapEmpty;
  final void Function(String, TimelineItem) onTapItem;

  const _DayColumn({
    super.key,
    required this.wrapItem,
    this.previewItem,
    this.previewStart,
    required this.day,
    required this.isToday,
    required this.hourHeight,
    required this.startMin,
    required this.fontScale,
    required this.maxColumns,
    required this.lineColor,
    required this.onTapEmpty,
    required this.onTapItem,
  });

  double _y(int min) => (min - startMin) / 60 * hourHeight;

  @override
  Widget build(BuildContext context) {
    // 今天列高亮(浅色底纹)
    final todayBg = Theme.of(context).colorScheme.primary
        .withValues(alpha: 0.06);
    final borderColor = isToday
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
        : lineColor;

    return Container(
      decoration: BoxDecoration(
        color: isToday ? todayBg : null,
        border: Border(
          left: BorderSide(color: lineColor, width: 0.5),
          bottom: BorderSide(color: lineColor, width: 0.5),
          top: BorderSide(color: borderColor, width: isToday ? 1.5 : 0.5),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, cons) {
          // 相交的时间块分配固定列；超出列数时保留一个汇总入口。
          final visible = (day?.items ?? [])
              .where((it) => it.endMin > startMin && it.startMin < 24 * 60)
              .toList();
          final placements = layoutTimeline(visible, maxColumns);
          return Stack(
            children: [
              // 小时横线 + 空白点击
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final min = (d.localPosition.dy / hourHeight * 60).floor();
                    if (day != null) {
                      onTapEmpty(
                        day!.date,
                        min.clamp(0, 1380),
                        (min + 60).clamp(1, 1440),
                      );
                    }
                  },
                  child: Column(
                    children: [
                      for (int h = startMin ~/ 60; h < 24; h++) ...[
                        SizedBox(
                          height: hourHeight,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              height: 1,
                              color: lineColor.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // 时间块按真实起止时间放置，整段保持同一列宽。
              if (day != null)
                for (final placement in placements)
                  Positioned(
                    // 列间留 2px，避免相邻卡片贴在一起。
                    top:
                        _y(
                          placement.startMin.clamp(startMin.toInt(), 24 * 60),
                        ) +
                        1,
                    left:
                        2 +
                        placement.lane *
                            (cons.maxWidth - 2) /
                            placement.columns,
                    width: ((cons.maxWidth - 2) / placement.columns - 2).clamp(
                      0,
                      cons.maxWidth,
                    ),
                    height:
                        (_y(placement.endMin.clamp(startMin.toInt(), 1440)) -
                                _y(
                                  placement.startMin.clamp(
                                    startMin.toInt(),
                                    1440,
                                  ),
                                ) -
                                2)
                            .clamp(1, 10000),
                    child: placement.item == null
                        ? _OverflowBlock(
                            count: placement.hiddenCount,
                            onTap: () => _showGroup(context, placement.group),
                          )
                        : wrapItem(
                            placement.item!,
                            _MiniBlock(
                              item: placement.item!,
                              fontScale: fontScale,
                              overlap: placement.columns > 1,
                              onTap: () =>
                                  onTapItem(day!.date, placement.item!),
                            ),
                          ),
                  ),
              if (previewItem != null && previewStart != null)
                Positioned(
                  top: _y(previewStart!).clamp(0, 100000),
                  left: 2,
                  right: 2,
                  height:
                      ((previewItem!.endMin - previewItem!.startMin) /
                              60 *
                              hourHeight)
                          .clamp(24, 10000),
                  child: IgnorePointer(
                    child: Transform.scale(
                      scale: 1.02,
                      child: _DragPreview(
                        item: previewItem!,
                        date: day!.date,
                        start: previewStart!,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showGroup(
    BuildContext context,
    List<TimelineItem> items,
  ) async {
    final selected = await showModalBottomSheet<TimelineItem>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.65,
          child: Column(
            children: [
              Text('这一组的全部安排', style: Theme.of(context).textTheme.titleMedium),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('${day!.date} · ${items.length} 项'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.type == 'class'
                            ? Icons.school_outlined
                            : (item.done
                                  ? Icons.check_circle_outline
                                  : Icons.radio_button_unchecked),
                        color: _parseHex(item.color),
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          decoration: item.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      subtitle: Text(
                        '${item.startLabel}–${item.endLabel}'
                        '${item.room == null ? '' : ' · ${item.room}'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, item),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && context.mounted) onTapItem(day!.date, selected);
  }
}

class _OverflowBlock extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _OverflowBlock({required this.count, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '另有 $count 项安排，点击查看这一组',
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: '另有 $count 项安排，查看全部',
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    '+$count',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部周几表头(周一~周日 + 日期、今天湖蓝)。与各列同宽/对齐，窄屏时随列一起横向滚动。
class _DayHeader extends StatelessWidget {
  final List<WeekDay> days;
  final String todayStr;
  final double dayW; // scrollable 时的固定列宽；0 表示用 Expanded 铺满
  final bool scrollable;

  const _DayHeader({
    required this.days,
    required this.todayStr,
    required this.dayW,
    required this.scrollable,
  });

  String _cn(int wd) =>
      const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][wd.clamp(1, 7)];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.bodySmall!;
    final cells = <Widget>[
      for (final d in days)
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_cn(d.weekday), style: labelStyle),
              const SizedBox(height: 2),
              Container(
                width: 34,
                padding: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  color: d.date == todayStr ? scheme.primary : null,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${DateTime.parse(d.date).day}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: d.date == todayStr ? Colors.white : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];

    if (!scrollable) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
        child: Row(children: cells),
      );
    }
    // 可滚：每列固定宽，与下方 DayColumn 对齐(直接左对齐，无小时刻度横向偏移)
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        width: dayW * days.length,
        child: Row(
          children: [
            for (final d in days)
              SizedBox(
                width: dayW,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_cn(d.weekday), style: labelStyle),
                    const SizedBox(height: 2),
                    Container(
                      width: 34,
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      decoration: BoxDecoration(
                        color: d.date == todayStr ? scheme.primary : null,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        '${DateTime.parse(d.date).day}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: d.date == todayStr
                              ? Colors.white
                              : scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 时间块保持整段宽度一致，窄列优先显示标题。
class _MiniBlock extends StatefulWidget {
  final TimelineItem item;
  final double fontScale;
  final bool overlap;
  final VoidCallback onTap;
  const _MiniBlock({
    required this.item,
    required this.fontScale,
    this.overlap = false,
    required this.onTap,
  });
  @override
  State<_MiniBlock> createState() => _MiniBlockState();
}

class _MiniBlockState extends State<_MiniBlock> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final color = _parseHex(item.color) ?? scheme.primary;
    final fill = Color.lerp(color, scheme.surface, _hover ? 0.72 : 0.86)!;
    final (title, parenNote) = splitTitleNote(item.title);
    final note = item.note ?? parenNote;
    return Tooltip(
      message: '${item.title}\n${item.startLabel}–${item.endLabel}',
      triggerMode: item.type == 'task'
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: item.done ? Color.lerp(fill, scheme.surface, 0.5) : fill,
          borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: widget.overlap ? 3 : 4,
                  child: ColoredBox(
                    color: color.withValues(alpha: item.done ? 0.4 : 0.95),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(7, 3, 3, 3),
                    child: LayoutBuilder(
                      builder: (context, cons) {
                        final titleFs = 10.5 * widget.fontScale;
                        final smallFs = 8.5 * widget.fontScale;
                        final scale = MediaQuery.textScalerOf(context);
                        final titleH = scale.scale(titleFs) * 1.2;
                        final smallH = scale.scale(smallFs) * 1.2;
                        final showTime = cons.maxHeight >= titleH + smallH + 2;
                        final showNote =
                            note != null &&
                            note.isNotEmpty &&
                            cons.maxWidth >= 70 &&
                            cons.maxHeight >= titleH * 2 + smallH * 2 + 4;
                        final reserved =
                            (showTime ? smallH + 2 : 0) +
                            (showNote ? smallH + 2 : 0);
                        final lines = ((cons.maxHeight - reserved) / titleH)
                            .floor()
                            .clamp(1, 3);
                        final textColor = item.done
                            ? scheme.outline
                            : scheme.onSurface;
                        return ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: lines,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: titleFs,
                                    height: 1.2,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                    decoration: item.done
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                if (showTime) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '${item.startLabel}–${item.endLabel}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: smallFs,
                                      height: 1.2,
                                      color: textColor.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                                if (showNote) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    note,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: smallFs,
                                      height: 1.2,
                                      color: textColor.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragPreview extends StatelessWidget {
  final TimelineItem item;
  final String date;
  final int start;

  const _DragPreview({
    required this.item,
    required this.date,
    required this.start,
  });

  String _clock(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _parseHex(item.color) ?? scheme.primary;
    final fill = Color.lerp(accent, scheme.surface, 0.84)!;
    final end = start + item.endMin - item.startMin;
    final parsedDate = DateTime.parse(date);
    final targetLabel =
        '${parsedDate.month.toString().padLeft(2, '0')}月${parsedDate.day.toString().padLeft(2, '0')}日 ${_clock(start)}–${_clock(end)}';

    return Container(
      key: const ValueKey('drag-preview-card'),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: accent.withValues(alpha: 0.72), width: 1),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(color: accent),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 3, 4, 3),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showTitle = constraints.maxHeight >= 39;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showTitle)
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 10.5,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (showTitle) const SizedBox(height: 2),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.topLeft,
                          child: Text(
                            targetLabel,
                            maxLines: 1,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.72),
                              fontSize: 9,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedOutlinePainter extends CustomPainter {
  final Color color;

  const _DashedOutlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(5)),
      );
    final metric = path.computeMetrics().first;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const dash = 5.0;
    const gap = 3.0;
    for (
      double distance = 0;
      distance < metric.length;
      distance += dash + gap
    ) {
      canvas.drawPath(
        metric.extractPath(distance, (distance + dash).clamp(0, metric.length)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedOutlinePainter oldDelegate) =>
      oldDelegate.color != color;
}

Color? _parseHex(String hex) {
  var s = hex.replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}
