import 'package:flutter/material.dart';

/// The date centers in the space between the left arrow and right controls.
class CalendarNavigationBar extends StatelessWidget
    implements PreferredSizeWidget {
  const CalendarNavigationBar({
    super.key,
    required this.title,
    required this.viewMenu,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });
  final Widget title, viewMenu;
  final VoidCallback onPrevious, onNext, onToday;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: false,
    centerTitle: false,
    titleSpacing: 8,
    title: Row(
      children: [
        SizedBox(
          width: 44,
          child: IconButton(
            tooltip: '上一段日期',
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
        ),
        Expanded(
          child: Padding(
            key: const ValueKey('calendar-date-group'),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: title),
          ),
        ),
        SizedBox(
          width: 44,
          child: IconButton(
            tooltip: '下一段日期',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ),
        SizedBox(width: 44, child: viewMenu),
        SizedBox(
          width: 44,
          child: IconButton(
            tooltip: '回到今天',
            onPressed: onToday,
            icon: const Icon(Icons.today_outlined),
          ),
        ),
      ],
    ),
  );
}
