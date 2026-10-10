import '../models.dart';

/// One fixed-width lane, or a summary of the lanes hidden in its group.
class TimelinePlacement {
  final TimelineItem? item;
  final List<TimelineItem> group;
  final int lane, columns, startMin, endMin, hiddenCount;
  const TimelinePlacement({
    this.item,
    required this.group,
    required this.lane,
    required this.columns,
    required this.startMin,
    required this.endMin,
    this.hiddenCount = 0,
  });
}

List<TimelinePlacement> layoutTimeline(
  List<TimelineItem> items,
  int maxColumns,
) {
  assert(maxColumns >= 2);
  final sorted = List<TimelineItem>.of(items)
    ..sort((a, b) {
      final start = a.startMin.compareTo(b.startMin);
      if (start != 0) return start;
      final end = b.endMin.compareTo(a.endMin);
      if (end != 0) return end;
      return '${a.type}:${a.id}:${a.title}'.compareTo(
        '${b.type}:${b.id}:${b.title}',
      );
    });
  final result = <TimelinePlacement>[];
  var group = <TimelineItem>[];
  var groupEnd = 0;
  void flush() {
    if (group.isEmpty) return;
    final laneEnds = <int>[];
    final lanes = <int>[];
    for (final item in group) {
      var lane = laneEnds.indexWhere((end) => end <= item.startMin);
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(item.endMin);
      } else {
        laneEnds[lane] = item.endMin;
      }
      lanes.add(lane);
    }
    final overflow = laneEnds.length > maxColumns;
    final columns = laneEnds.length.clamp(1, maxColumns);
    final hidden = <TimelineItem>[];
    for (var i = 0; i < group.length; i++) {
      final item = group[i];
      if (overflow && lanes[i] >= maxColumns - 1) {
        hidden.add(item);
      } else {
        result.add(
          TimelinePlacement(
            item: item,
            group: group,
            lane: lanes[i],
            columns: columns,
            startMin: item.startMin,
            endMin: item.endMin,
          ),
        );
      }
    }
    if (hidden.isNotEmpty) {
      result.add(
        TimelinePlacement(
          group: group,
          lane: columns - 1,
          columns: columns,
          startMin: hidden.first.startMin,
          endMin: hidden.map((it) => it.endMin).reduce((a, b) => a > b ? a : b),
          hiddenCount: hidden.length,
        ),
      );
    }
    group = [];
  }

  for (final item in sorted) {
    if (group.isNotEmpty && item.startMin >= groupEnd) flush();
    if (group.isEmpty) groupEnd = item.endMin;
    group.add(item);
    if (item.endMin > groupEnd) groupEnd = item.endMin;
  }
  flush();
  return result;
}
