import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/network_client.dart';

String token(int uid) =>
    'x.${base64Url.encode(utf8.encode(jsonEncode({'uid': uid, 'exp': 4102444800})))}.x';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('AI provider errors preserve structured failure and cooldown without retrying POST', () async {
    var calls = 0;
    final net = NetworkClient(
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response(
          '{"error":"AI unavailable","code":"AI_PROVIDER_UNAVAILABLE","retryAfterSeconds":30}',
          502,
        );
      }),
    );
    await expectLater(
      net.request(
        'POST',
        Uri.parse('https://example.test/api/ai/sessions'),
        token(1),
        {'message': 'keep'},
      ),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'AI_PROVIDER_UNAVAILABLE')
            .having((e) => e.details?['retryAfterSeconds'], 'cooldown', 30),
      ),
    );
    expect(calls, 1);
  });
  test(
    'email rejection keeps server explanation and never retries POST',
    () async {
      var calls = 0;
      final net = NetworkClient(
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'error': '测试版请先联系开发者添加测试邮箱',
              'code': 'EMAIL_TEST_RECIPIENT_ONLY',
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await expectLater(
        net.request(
          'POST',
          Uri.parse('https://example.test/api/account/email/code'),
          token(1),
          {},
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'explanation', '测试版请先联系开发者添加测试邮箱')
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.code, 'code', 'EMAIL_TEST_RECIPIENT_ONLY'),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'unstructured email server failure remains uncertain and is not retried',
    () async {
      var calls = 0;
      final net = NetworkClient(
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('<html>gateway unavailable</html>', 502);
        }),
      );
      await expectLater(
        net.request(
          'POST',
          Uri.parse('https://example.test/api/account/email'),
          token(1),
          {},
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'uncertain',
            contains('未能确认保存结果'),
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test('offline cache is read-only and scoped to account; auth failures never use cache', () async {
    var mode = 0, calls = 0;
    final net = NetworkClient(
      clientFactory: () => MockClient((r) async {
        calls++;
        if (mode == 1) throw http.ClientException('offline');
        if (mode == 2) return http.Response('{"error":"expired"}', 401);
        return http.Response('[{"title":"private"}]', 200);
      }),
    );
    final uri = Uri.parse('https://example.test/api/inbox');
    await net.request('GET', uri, token(1));
    mode = 1;
    expect((await net.request('GET', uri, token(1)) as List).length, 1);
    expect(net.warning.value, isNotNull);
    await expectLater(
      net.request('GET', uri, token(2)),
      throwsA(isA<ApiException>()),
    );
    final before = calls;
    await expectLater(
      net.request('POST', uri, token(1), {'title': 'save'}),
      throwsA(isA<ApiException>()),
    );
    expect(calls - before, 1);
    mode = 2;
    await expectLater(
      net.request('GET', uri, token(1)),
      throwsA(isA<ApiException>()),
    );
  });
  test(
    'hung request times out; non-JSON failures become actionable errors',
    () async {
      final net = NetworkClient(
        timeout: const Duration(milliseconds: 5),
        clientFactory: () => MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('bad gateway', 502);
        }),
      );
      await expectLater(
        net.request(
          'POST',
          Uri.parse('https://example.test/api/inbox'),
          token(1),
          {},
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
