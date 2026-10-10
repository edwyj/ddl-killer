import 'offline_sync.dart';
import 'network_client.dart';

Future<void> ensureAiCalendarSynced(OfflineSync offline) async {
  if (offline.pendingCount == 0) return;
  await offline.sync();
  if (offline.pendingCount > 0) {
    throw ApiException(
      '还有本机修改未同步，请先完成同步，再让 AI 安排或应用方案。',
      code: 'AI_SYNC_REQUIRED',
    );
  }
}
