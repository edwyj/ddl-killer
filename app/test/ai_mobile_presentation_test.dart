import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';
import 'package:plan_app/theme.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:plan_app/api.dart';

import 'ai_planner_sheet_test.dart' show FakePlannerRepository;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'NotoColorEmoji',
    )..addFont(rootBundle.load('assets/fonts/NotoColorEmoji.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final dark in [false, true]) {
    testWidgets('AI mobile presentation dark=$dark with keyboard and result', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakePlannerRepository();
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          home: Scaffold(
            body: Dialog(
              insetPadding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 680,
                  maxHeight: 720,
                ),
                child: RepaintBoundary(
                  key: const ValueKey('ai-preview'),
                  child: Material(child: AiPlannerSheet(repository: repo)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('ai-preview')),
        matchesGoldenFile('goldens/ai-mobile-${dark ? 'dark' : 'light'}.png'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '明天写报告',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('ai-preview')),
        matchesGoldenFile('goldens/ai-result-${dark ? 'dark' : 'light'}.png'),
      );
      repo.result = AiTurnResult(
        sessionId: repo.result.sessionId,
        draft: const AiDraft(id: 'no-change', status: 'pending', changes: [], warnings: []),
        summary: '好的，保持现有安排，不做调整。',
        questions: const [], warnings: const [], quota: repo.result.quota,
      );
      await tester.enterText(find.byKey(const ValueKey('ai-planner-input')), '保持不变');
      await tester.tap(find.byTooltip('调整方案'));
      await tester.pumpAndSettle();
      expect(find.text('应用安排'), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('ai-preview')),
        matchesGoldenFile('goldens/ai-no-change-${dark ? 'dark' : 'light'}.png'));
      repo.error = ApiException('频繁', code: 'AI_RATE_LIMITED', statusCode: 429,
        details: {'retryAfterSeconds': 30});
      await tester.enterText(find.byKey(const ValueKey('ai-planner-input')), '明天再加一段散步');
      await tester.tap(find.byTooltip('调整方案'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('ai-preview')),
        matchesGoldenFile('goldens/ai-cooldown-${dark ? 'dark' : 'light'}.png'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
