import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/community_state.dart';

void main() {
  test(
    'a refresh beyond the cached page keeps missing history reachable',
    () async {
      var request = 0;
      final state = CommunityState(
        loader: (_) async => ++request == 1
            ? {
                'items': [
                  {'id': 3},
                  {'id': 2},
                  {'id': 1},
                ],
                'unread': 3,
                'hasMore': false,
              }
            : {
                'items': [
                  {'id': 5},
                  {'id': 4},
                ],
                'unread': 5,
                'hasMore': true,
              },
      );
      await state.attach(1, persistent: false);
      await state.refreshMessages();
      await state.refreshMessages();
      expect(state.hasMoreMessages, true);
      expect(state.messages.last['id'], 4);
    },
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'repeated loads coalesce; account changes discard late private responses',
    () async {
      final requests = <Completer<Map<String, dynamic>>>[];
      final store = CommunityState(
        loader: (path) {
          final c = Completer<Map<String, dynamic>>();
          requests.add(c);
          return c.future;
        },
      );
      await store.attach(1, persistent: true);
      final first = store.refreshMessages();
      final second = store.refreshMessages();
      expect(requests.length, 1);
      await store.attach(2, persistent: true);
      requests.first.complete({
        'items': [
          {'id': 1, 'body': 'private'},
        ],
        'unread': 1,
      });
      await Future.wait([first, second]);
      expect(store.messages, isEmpty);
      expect(store.unread, 0);
    },
  );
  test('cached messages show immediately and survive refresh failure; public devices do not persist', () async {
    var fail = false;
    final store = CommunityState(
      loader: (_) async {
        if (fail) throw StateError('offline');
        return {
          'items': [
            {'id': 1, 'title': 'welcome'},
          ],
          'unread': 1,
        };
      },
    );
    await store.attach(1, persistent: true);
    await store.refreshMessages();
    fail = true;
    await store.refreshMessages();
    expect(store.unread, 1);
    expect(store.messages.length, 1);
    expect(store.messageError, isNotNull);
    final restored = CommunityState(
      loader: (_) async => throw StateError('offline'),
    );
    await restored.attach(1, persistent: true);
    expect(restored.messages.length, 1);
    await restored.attach(2, persistent: false);
    expect(restored.messages, isEmpty);
    final pref = await SharedPreferences.getInstance();
    expect(pref.getString('community_messages_v1_2'), isNull);
  });
}
