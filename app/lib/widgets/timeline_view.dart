import 'package:flutter/material.dart';
import '../models.dart';

/// 每日 00:00-24:00 纵向时间轴。课程/任务块按 start_min 绝对定位。
class TimelineView extends StatelessWidget {
  final List<TimelineItem> items;
  final bool isToday;
  final int nowMin; // 今天的当前分钟数(仅 isToday 用)
  final double hourHeight;
  final void Function(int startMin, int endMin) onTapEmpty;
  final void Function(TimelineItem item) onTapItem;

  const TimelineView({
    super.key,
    required this.items,
    required this.isToday,
    required this.nowMin,
    required this.onTapEmpty,
    required this.onTapItem,
    this.hourHeight = 60,
  });

  double _y(int min) => min / 60 * hourHeight;

  @override
  Widget build(BuildContext context) {
    final total = _y(1440);
    const labelWidth = 52.0;
    final gridColor = Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.35);
    final labelStyle = Theme.of(context).textTheme.bodySmall!.copyWith(
          fontSize: 11,
          color: Theme.of(context).colorScheme.outline,
        );

    return SingleChildScrollView(
      child: SizedBox(
        height: total,
        child: Stack(
          children: [
                // 背景(接收空白处点击)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) {
                      final min = (d.localPosition.dy / hourHeight * 60).floor();
                      onTapEmpty(min.clamp(0, 1380), (min + 60).clamp(1, 1440));
                    },
                  ),
                ),
                // 小时刻度线 + 标签
                for (int h = 0; h <= 24; h++)
                  Positioned(
                    top: _y(h * 60) - 1,
                    left: 0,
                    right: 0,
                    height: 1,
                    child: Container(
                      color: h == 0 ? gridColor.withValues(alpha: 0.8) : gridColor,
                    ),
                  ),
                for (int h = 0; h <= 24; h++)
                  Positioned(
                    top: _y(h * 60) - 7,
                    left: 6,
                    width: labelWidth - 10,
                    child: Text(
                      h == 24 ? '0:00' : '$h:00',
                      style: labelStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                // 现在时间线(今天)
                if (isToday)
                  Positioned(
                    top: _y(nowMin),
                    left: labelWidth,
                    right: 0,
                    child: Container(
                      height: 2,
                      color: Colors.redAccent.withValues(alpha: 0.85),
                    ),
                  ),
                // 时间块
                for (final item in items)
                  Positioned(
                    top: _y(item.startMin),
                    left: labelWidth + 8,
                    right: 8,
                    height: (_y(item.endMin) - _y(item.startMin) - 2).clamp(18, 1000),
                    child: _BlockCard(item: item, onTap: () => onTapItem(item)),
                  ),
              ],
            ),
          ),
        );
  }
}

class _BlockCard extends StatelessWidget {
  final TimelineItem item;
  final VoidCallback onTap;

  const _BlockCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isClass = item.type == 'class';
    final color = _parseHex(item.color) ?? (isClass ? const Color(0xFF4A90D9) : const Color(0xFF8E7CC3));
    final done = item.done;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: done ? 0.25 : (isClass ? 0.28 : 0.30)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: done ? 0.3 : 0.7), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
                decoration: done ? TextDecoration.lineThrough : null,
              ),
            ),
            Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.55)),
            ),
          ],
        ),
      ),
    );
  }

  String get _subtitle {
    final t = '${item.startLabel}-${item.endLabel}';
    if (item.type == 'class') {
      final parts = [if (item.room != null) item.room!, if (item.teacher != null) item.teacher!];
      return parts.isEmpty ? t : '$t · ${parts.join(' · ')}';
    }
    return t;
  }
}

Color? _parseHex(String hex) {
  var s = hex.replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}
