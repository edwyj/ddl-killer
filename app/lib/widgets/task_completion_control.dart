import 'package:flutter/material.dart';

/// One completion affordance for Today, lists and DDL. The visible mark can be
/// smaller on phones without reducing its touch or keyboard target.
class TaskCompletionControl extends StatelessWidget {
  const TaskCompletionControl({
    super.key,
    required this.done,
    required this.color,
    required this.title,
    required this.onToggle,
    this.actionLabel,
  });
  final bool done;
  final Color color;
  final String title;
  final VoidCallback onToggle;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final size = compact ? 20.0 : 26.0;
    final label = actionLabel ?? '${done ? '取消完成' : '完成'}「$title」';
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: MergeSemantics(
        child: Semantics(
          label: label,
          checked: done,
          button: true,
          child: SizedBox(
            width: 44,
            height: 44,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(10),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: done
                        ? color.withValues(alpha: 0.15)
                        : Colors.transparent,
                    border: Border.all(color: color, width: 1.5),
                    borderRadius: BorderRadius.circular(compact ? 5 : 7),
                  ),
                  child: done
                      ? Icon(Icons.check, size: compact ? 14 : 18, color: color)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
