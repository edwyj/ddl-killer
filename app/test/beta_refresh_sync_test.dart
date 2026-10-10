import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:plan_app/offline_sync.dart';

void main() {
  test('Beta snapshot refresh discards old queued edits before transport can replay them', () async {
    var generation = 'first', online = true, posted = 0;
    final sync = OfflineSync(
      transport: (method, path, body) async {
        if (!online) throw Exception('offline');
        if (method == 'POST') {
          posted++;
          throw Exception('should not replay');
        }
        return {
          'schema': 1,
          'uid': 2,
          'generation': generation,
          'profile': {'id': 2, 'username': 'tester_alpha'},
          'lists': [],
          'tasks': [],
          'blocks': [],
          'schedule': null,
        };
      },
    );
    await sync.initialize(
      database: await databaseFactoryMemory.openDatabase('beta-test'),
    );
    await sync.attach(2, 'tester_alpha');
    await sync.sync();
    online = false;
    await sync.mutate('POST', '/api/lists', {'name': 'old beta change'});
    await sync.sync();
    expect(sync.pendingCount, 1);
    generation = 'second';
    online = true;
    await sync.sync();
    expect(posted, 0);
    expect(sync.pendingCount, 0);
    expect(sync.view['generation'], 'second');
    expect(sync.view['lists'], isEmpty);
    sync.dispose();
  });
}
