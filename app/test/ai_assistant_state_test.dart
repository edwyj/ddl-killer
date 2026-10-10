import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/ai_assistant_state.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:shared_preferences/shared_preferences.dart';

AiAssistantSettings settings({bool enabled = true, int remaining = 2}) =>
    AiAssistantSettings(
      mode: AiProviderMode.hosted,
      provider: null,
      quota: AiQuota(
        limit: 3,
        used: 3 - remaining,
        reserved: 0,
        remaining: remaining,
        resetsAt: DateTime.utc(2026, 9, 29),
        hostedEnabled: true,
        copy: '测试阶段',
      ),
      featureEnabled: enabled,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'deduplicates refresh and returns memory cache on repeated entry',
    () async {
      final completer = Completer<AiAssistantSettings>();
      var calls = 0;
      final store = AiAssistantStateStore(() {
        calls++;
        return calls == 1 ? completer.future : Future.value(settings());
      });

      final first = store.refresh();
      final second = store.refresh();
      expect(calls, 1);
      completer.complete(settings());
      expect(await first, same(await second));
      final cached = store.settings;
      expect(await store.load(), same(cached));
      expect(calls, 2);
    },
  );

  test('persists only account-scoped feature availability', () async {
    final store = AiAssistantStateStore(() async => settings());
    await store.preload(42);
    await store.refresh();
    final preferences = await SharedPreferences.getInstance();

    expect(preferences.getBool('ai_feature_enabled_v1_42'), isTrue);
    expect(preferences.getInt('ai_feature_checked_at_v1_42'), isNotNull);
    expect(
      preferences.getKeys().where((key) {
        final value = preferences.get(key).toString();
        return value.contains('provider') || value.contains('keyMask');
      }),
      isEmpty,
    );
  });

  test(
    'account change clears in-memory settings and loads matching flag',
    () async {
      SharedPreferences.setMockInitialValues({
        'ai_feature_enabled_v1_7': false,
        'ai_feature_enabled_v1_8': true,
      });
      final store = AiAssistantStateStore(() async => settings());
      await store.preload(7);
      expect(store.featureEnabled, isFalse);
      await store.refresh();
      expect(store.settings, isNotNull);

      await store.preload(8);
      expect(store.settings, isNull);
      expect(store.featureEnabled, isTrue);
    },
  );
}
