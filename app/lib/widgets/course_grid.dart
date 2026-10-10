import 'package:flutter/material.dart';
import '../models.dart';

/// 课表彩色网格：节次(1-5大节) × 星期(一~日)，每格一门课彩块(名称+教室)，今天高亮。
class CourseGrid extends StatelessWidget {
  final List<WeekDay> days; // 一周(周一~周日)
  final String todayStr;

  const CourseGrid({super.key, required this.days, required this.todayStr});

  static const _blockTimes = {
    1: '08:00-10:00',
    2: '10:00-12:00',
    3: '14:00-16:00',
    4: '16:00-18:00',
    5: '19:00-21:00',
  };
  static const _labelW = 60.0;
  static const _colW = 116.0;
  static const _cellH = 86.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _labelW + days.length * (_colW + 6),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: _labelW),
                  for (final d in days) _headerCell(context, d, scheme),
                ],
              ),
              const SizedBox(height: 8),
              for (var b = 1; b <= 5; b++) _blockRow(context, b, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCell(BuildContext context, WeekDay d, ColorScheme scheme) {
    final isToday = d.date == todayStr;
    final date = DateTime.parse(d.date);
    return Container(
      width: _colW,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: isToday ? scheme.primary.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(8),
        border: isToday ? Border.all(color: scheme.primary.withValues(alpha: 0.6), width: 1.2) : null,
      ),
      child: Column(
        children: [
          Text('周${_cn(d.weekday)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
          Text('${date.month}/${date.day}', style: TextStyle(fontSize: 11, color: isToday ? scheme.primary : scheme.outline)),
        ],
      ),
    );
  }

  Widget _blockRow(BuildContext context, int block, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: _labelW,
            padding: const EdgeInsets.only(right: 8, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$block', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface)),
                Text(_blockTimes[block] ?? '', style: TextStyle(fontSize: 9, color: scheme.outline)),
              ],
            ),
          ),
          for (final d in days) _cell(context, d, block),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, WeekDay d, int block) {
    final classes = d.items.where((i) => i.type == 'class' && i.block == block).toList();
    return Container(
      width: _colW,
      height: _cellH,
      margin: const EdgeInsets.only(right: 6),
      child: classes.isEmpty
          ? Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
              ),
            )
          : _courseBlock(context, classes.first),
    );
  }

  Widget _courseBlock(BuildContext context, TimelineItem c) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = _hex(c.color) ?? const Color(0xFF5C8DEF);
    final fill = Color.lerp(color, isDark ? const Color(0xFF1F1F24) : Colors.white, 0.76)!;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : const Color(0xFF23232B),
            ),
          ),
          const Spacer(),
          Text(c.room ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 8.5, color: color)),
        ],
      ),
    );
  }

  static String _cn(int wd) => const ['', '一', '二', '三', '四', '五', '六', '日'][wd.clamp(1, 7)];

  static Color? _hex(String hex) {
    if (hex.length < 7) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }
}
