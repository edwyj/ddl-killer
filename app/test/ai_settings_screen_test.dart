import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:plan_app/screens/ai_settings_screen.dart';
import 'package:plan_app/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const betaCopy = 'AI 计划助手目前处于测试阶段，免费额度可能随成本和运行情况调整，敬请谅解。';

class FakeAiSettingsRepository implements AiSettingsRepository {
  FakeAiSettingsRepository({required this.settings});

  AiAssistantSettings settings;
  Object? saveError;
  var saves = <AiProviderInput>[];
  var tests = 0;
  var deletes = 0;

  @override
  Future<AiAssistantSettings> load() async => settings;

  @override
  Future<void> setMode(AiProviderMode mode, {String? password}) async {
    settings = settings.copyWith(mode: mode);
  }

  @override
  Future<AiProviderSummary> saveProvider(AiProviderInput input) async {
    if (saveError case final error?) throw error;
    saves.add(input);
    return AiProviderSummary(
      provider: input.provider,
      baseUrl: input.baseUrl,
      model: input.model,
      keyMask: '••••1234',
      updatedAt: DateTime(2026, 9, 27),
    );
  }

  @override
  Future<void> testProvider({String? password}) async => tests++;

  @override
  Future<void> deleteProvider({String? password}) async => deletes++;
}

AiAssistantSettings sampleSettings({AiProviderSummary? provider}) =>
    AiAssistantSettings(
      mode: AiProviderMode.byok,
      provider:
          provider ??
          AiProviderSummary(
            provider: 'deepseek',
            baseUrl: 'https://api.deepseek.com/v1',
            model: 'deepseek-chat',
            keyMask: '••••1234',
            updatedAt: DateTime(2026, 9, 27),
          ),
      quota: AiQuota(
        limit: 3,
        used: 1,
        reserved: 0,
        remaining: 2,
        resetsAt: DateTime.utc(2026, 9, 27, 16),
        hostedEnabled: true,
        copy: betaCopy,
      ),
    );

Future<FakeAiSettingsRepository> pumpSettings(
  WidgetTester tester, {
  FakeAiSettingsRepository? repository,
}) async {
  final repo =
      repository ?? FakeAiSettingsRepository(settings: sampleSettings());
  await tester.pumpWidget(
    MaterialApp(home: AiSettingsScreen(repository: repo)),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'new DeepSeek configuration defaults to Flash and links tutorial',
    (tester) async {
      final repo = FakeAiSettingsRepository(
        settings: sampleSettings().copyWith(clearProvider: true),
      );
      await pumpSettings(tester, repository: repo);
      await tester.scrollUntilVisible(
        find.text('模型名称'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('deepseek-flash'), findsOneWidget);
      expect(find.text('deepseek-chat'), findsNothing);
      await tester.ensureVisible(find.text('API Key 获取与配置教程'));
      await tester.pumpAndSettle();
      String? opened;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            opened = (call.arguments as Map)['url'] as String;
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.tap(find.text('API Key 获取与配置教程'));
      await tester.pumpAndSettle();
      expect(opened, 'https://ddlkiller.com/website/api-key-help.html');
    },
  );

  testWidgets(
    'saved model is preserved; switching back to DeepSeek uses Flash',
    (tester) async {
      await pumpSettings(tester);
      await tester.ensureVisible(find.text('模型名称'));
      await tester.pumpAndSettle();
      expect(find.text('deepseek-chat'), findsOneWidget);
      await tester.ensureVisible(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义 OpenAI 兼容服务').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义 OpenAI 兼容服务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek').last);
      await tester.pumpAndSettle();
      expect(find.text('deepseek-flash'), findsOneWidget);
    },
  );

  testWidgets('beta quota warning and masked provider are visible', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.textContaining('测试阶段'), findsOneWidget);
    expect(find.textContaining('免费额度可能'), findsOneWidget);
    expect(find.textContaining('还可免费生成 2 次'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('1234'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('1234'), findsOneWidget);
    expect(find.textContaining('sk-'), findsNothing);
  });

  testWidgets(
    'failed save retains key and asks for password after recent-login error',
    (tester) async {
      final repo = FakeAiSettingsRepository(settings: sampleSettings())
        ..saveError = ApiException('需要验证', code: 'RECENT_AUTH_REQUIRED');
      await pumpSettings(tester, repository: repo);
      await tester.enterText(
        find.byKey(const ValueKey('ai-key-field')),
        'sk-money-secret',
      );
      await tester.ensureVisible(find.text('保存配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();

      expect(find.text('sk-money-secret'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-password-field')), findsOneWidget);
      expect(repo.saves, isEmpty);
    },
  );

  testWidgets(
    'successful save clears sensitive controllers and never writes shared preferences',
    (tester) async {
      final repo = await pumpSettings(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-key-field')),
        'sk-money-secret',
      );
      await tester.ensureVisible(find.text('保存配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();

      expect(repo.saves.single.key, 'sk-money-secret');
      expect(find.text('sk-money-secret'), findsNothing);
      final values = await SharedPreferences.getInstance();
      expect(
        values.getKeys().where(
          (key) => values.get(key).toString().contains('sk-money-secret'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('custom provider requires domain confirmation before save', (
    tester,
  ) async {
    final repo = await pumpSettings(tester);
    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义 OpenAI 兼容服务').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url-field')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-key-field')),
      'secret-value',
    );
    await tester.ensureVisible(find.text('保存配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('api.example.com'),
      ),
      findsOneWidget,
    );
    expect(repo.saves, isEmpty);
    await tester.tap(find.text('确认并保存'));
    await tester.pumpAndSettle();
    expect(repo.saves.single.baseUrl, 'https://api.example.com/v1');
  });

  testWidgets('test and delete actions call repository', (tester) async {
    final repo = await pumpSettings(tester);
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('删除配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(repo.tests, 1);
    expect(repo.deletes, 1);
  });
}
