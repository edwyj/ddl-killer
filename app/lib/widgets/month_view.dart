import 'package:flutter/material.dart';

/// 月视图：月份日历网格，有内容的日子显示彩点，今天湖蓝实心圆，点某天进入单日。
class MonthView extends StatelessWidget {
  final DateTime month;
  final Map<String, int> dayMarks; // date -> 当天内容数(课+任务)
  final String todayStr;
  final void Function(String date) onPickDay;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPickMonth; // 点击月份弹年月选择

  const MonthView({
    super.key,
    required this.month,
    required this.dayMarks,
    required this.todayStr,
    required this.onPickDay,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPickMonth,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final prevMonth = DateTime(month.year, month.month, 0);
    final daysInPrev = prevMonth.day;
    final lead = first.weekday - 1; // 月初前的空位
    final gridCount = ((lead + daysInMonth + 6) ~/ 7) * 7;

    return Column(
      children: [
        // 顶栏：月份(可点击选择) + 翻月 + 今天
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
              Expanded(
                child: Center(
                  child: InkWell(
                    onTap: onPickMonth,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      child: Text(
                        '${month.month}月',
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
              TextButton(onPressed: onToday, child: const Text('今天')),
            ],
          ),
        ),
        // 周几表头
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(w, style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 日期网格
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: gridCount,
            itemBuilder: (ctx, i) {
              final dayNum = i - lead + 1;
              // 相邻月淡显
              if (dayNum < 1) {
                final d = daysInPrev + dayNum;
                return _DayCell(dayNum: d, faded: true, onTap: () => onPickDay(_prevDateStr(prevMonth.month, d)));
              }
              if (dayNum > daysInMonth) {
                final d = dayNum - daysInMonth;
                return _DayCell(dayNum: d, faded: true, onTap: () => onPickDay(_nextDateStr(d)));
              }
              final dateStr = '${month.year}-${month.month.toString().padLeft(2, '0')}-${dayNum.toString().padLeft(2, '0')}';
              final isToday = dateStr == todayStr;
              final count = dayMarks[dateStr] ?? 0;
              return _DayCell(
                dayNum: dayNum,
                isToday: isToday,
                hasContent: count > 0,
                onTap: () => onPickDay(dateStr),
              );
            },
          ),
        ),
      ],
    );
  }

  String _prevDateStr(int m, int d) {
    final dt = DateTime(month.year, m, d);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _nextDateStr(int d) {
    final dt = DateTime(month.year, month.month + 1, d);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

class _DayCell extends StatelessWidget {
  final int dayNum;
  final bool isToday;
  final bool hasContent;
  final bool faded;
  final VoidCallback onTap;

  const _DayCell({required this.dayNum, this.isToday = false, this.hasContent = false, this.faded = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = faded ? scheme.outline.withValues(alpha: 0.4) : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isToday ? scheme.primary : null,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$dayNum',
                style: TextStyle(
                  color: isToday ? Colors.white : base,
                  fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            SizedBox(
              height: 6,
              child: hasContent
                  ? Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(top: 3),
                      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
