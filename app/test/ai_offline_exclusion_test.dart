import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/network_client.dart';
import 'package:plan_app/offline_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

String token() =>
    'x.${base64Url.encode(utf8.encode(jsonEncode({'uid': 7, 'exp': 4102444800})))}.x';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AI endpoints never enter the offline mutation queue', () {
    final sync = OfflineSync(transport: (_, __, ___) async => {});
    expect(sync.handles('/api/ai/settings'), false);
    expect(sync.handles('/api/ai/provider'), false);
    expect(sync.handles('/api/ai/sessions'), false);
    expect(sync.handles('/api/ai/sessions/session-1'), false);
    expect(sync.handles('/api/ai/sessions/session-1/close'), false);
    sync.dispose();
  });

  test(
    'AI responses and provider masks are not persisted in read cache',
    () async {
      SharedPreferences.setMockInitialValues({});
      var offline = false;
      final client = NetworkClient(
        clientFactory: () => MockClient((_) async {
          if (offline) throw http.ClientException('offline');
          return http.Response('{"keyMask":"sk-sentinel-mask"}', 200);
        }),
      );
      final uri = Uri.parse('https://example.test/api/ai/provider');
      await client.request('GET', uri, token());
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getKeys().where((key) => key.startsWith('read_cache_v1_')),
        isEmpty,
      );

      offline = true;
      await expectLater(
        client.request('GET', uri, token()),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
