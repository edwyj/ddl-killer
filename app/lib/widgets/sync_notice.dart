import 'package:flutter/material.dart';

/// Only unsent changes interrupt the task view. Details remain in settings.
class SyncNotice extends StatelessWidget {
  const SyncNotice({
    super.key,
    required this.pendingCount,
    required this.needsLogin,
    required this.hasConflict,
    required this.onTap,
  });
  final int pendingCount;
  final bool needsLogin, hasConflict;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (pendingCount == 0) return const SizedBox.shrink();
    final text = hasConflict
        ? '$pendingCount 项修改待同步 · 需要处理冲突'
        : needsLogin
        ? '$pendingCount 项修改待同步 · 请重新登录'
        : '$pendingCount 项修改待同步';
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                Icon(
                  hasConflict || needsLogin
                      ? Icons.sync_problem_outlined
                      : Icons.cloud_upload_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
