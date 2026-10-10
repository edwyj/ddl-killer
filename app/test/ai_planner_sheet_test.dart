import 'dart:async';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/voice_input.dart';

import 'voice_input_test.dart' show FakeRecorder;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';

class FakePlannerRepository implements AiPlannerRepository {
  var creates = 0;
  var turns = 0;
  var closes = 0;
  var deletes = 0;
  var applies = 0;
  Object? error;
  Completer<AiTurnResult>? pending;
  AiTurnResult result = sampleResult('draft-1', 600);
  List<AiSessionSummary> history = const [];
  AiSessionDetail? detail;

  @override
  Future<AiTurnResult> createSession(
    String message,
    DateTime start,
    DateTime end,
  ) {
    creates++;
    if (error case final value?) return Future.error(value);
    return pending?.future ?? Future.value(result);
  }

  @override
  Future<AiTurnResult> addTurn(String sessionId, String message) {
    turns++;
    if (error case final value?) return Future.error(value);
    return Future.value(result);
  }

  @override
  Future<List<AiSessionSummary>> listSessions() async => history;

  @override
  Future<AiSessionDetail> getSession(String sessionId) async => detail!;

  @override
  Future<void> closeSession(String sessionId) async => closes++;

  @override
  Future<void> deleteSession(String sessionId) async => deletes++;

  @override
  Future<void> applyDraft(String draftId) async => applies++;
}

AiTurnResult sampleResult(String draftId, int start) => AiTurnResult(
  sessionId: 'session-1',
  draft: AiDraft(
    id: draftId,
    status: 'pending',
    changes: [
      AiDraftChange(
        operation: 'schedule_task',
        title: '写报告',
        date: '2026-09-28',
        start: start,
        end: start + 60,
        reason: '优先处理临近截止的任务',
        before: '未安排',
      ),
    ],
    warnings: const [
      AiPlanningWarning(
        code: 'TIME_OVERLAP',
        message: '与午饭重叠',
        blocking: false,
      ),
    ],
  ),
  summary: '先完成写报告',
  questions: const ['是否保留午休？'],
  warnings: const ['这是初步建议'],
  quota: AiQuota(
    limit: 3,
    used: 1,
    reserved: 0,
    remaining: 2,
    resetsAt: DateTime.utc(2026, 9, 28),
    hostedEnabled: true,
    copy: 'AI 计划助手目前处于测试阶段，免费额度可能随成本和运行情况调整，敬请谅解。',
  ),
);

Future<FakePlannerRepository> pumpSheet(
  WidgetTester tester, {
  FakePlannerRepository? repository,
  bool showIntro = false,
  VoidCallback? onApplied,
}) async {
  final repo = repository ?? FakePlannerRepository();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiPlannerSheet(
          key: UniqueKey(),
          repository: repo,
          showIntro: showIntro,
          onIntroSeen: () async {},
          onApplied: onApplied,
        ),
      ),
    ),
  );
  await tester.pump();
  return repo;
}

void main() {
  final desktopPlatforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  });
  Future<FakePlannerRepository> desktopInput(
    WidgetTester tester, {
    FakePlannerRepository? repository,
  }) async {
    return pumpSheet(tester, repository: repository);
  }

  testWidgets('desktop Enter sends once without inserting a newline', (
    tester,
  ) async {
    final repo = await desktopInput(tester);
    final input = find.byKey(const ValueKey('ai-planner-input'));
    await tester.enterText(input, '安排报告');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.creates, 1);
    expect(repo.turns, 0);
    expect(find.text('先完成写报告'), findsOneWidget);
  }, variant: desktopPlatforms);

  for (final modifier in [
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.controlLeft,
  ]) {
    testWidgets('desktop $modifier Enter inserts a newline at the selection', (
      tester,
    ) async {
      final repo = await desktopInput(tester);
      final input = find.byKey(const ValueKey('ai-planner-input'));
      await tester.enterText(input, '今天复习报告');
      final controller = tester.widget<TextField>(input).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 4,
      );
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(controller.text, '今天\n报告');
      expect(controller.selection.baseOffset, 3);
      expect(repo.creates, 0);
    }, variant: desktopPlatforms);
  }

  testWidgets('desktop Enter does not send while IME composition is active', (
    tester,
  ) async {
    final repo = await desktopInput(tester);
    final input = find.byKey(const ValueKey('ai-planner-input'));
    await tester.enterText(input, '安排');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '安排报告',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(repo.creates, 0);
    // The input method commits the candidate before a later Enter sends.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '安排报告',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.creates, 1);
  }, variant: desktopPlatforms);

  testWidgets('desktop Enter handles numpad and ignores empty/repeated sends', (
    tester,
  ) async {
    final repo = FakePlannerRepository()..pending = Completer<AiTurnResult>();
    await desktopInput(tester, repository: repo);
    final input = find.byKey(const ValueKey('ai-planner-input'));
    await tester.tap(input);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(repo.creates, 0);
    await tester.enterText(input, '安排报告');
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.numpadEnter,
      platform: 'web',
    );
    await tester.sendKeyRepeatEvent(
      LogicalKeyboardKey.numpadEnter,
      platform: 'web',
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.numpadEnter,
      platform: 'web',
    );
    await tester.pump();
    expect(repo.creates, 1);
    repo.pending!.complete(sampleResult('draft-keyboard', 600));
    await tester.pumpAndSettle();
  }, variant: desktopPlatforms);

  testWidgets(
    'desktop cooldown blocks Enter sending but permits editing newlines',
    (tester) async {
      final repo = FakePlannerRepository()
        ..error = ApiException(
          '频繁',
          code: 'AI_RATE_LIMITED',
          statusCode: 429,
          details: {'retryAfterSeconds': 3},
        );
      await desktopInput(tester, repository: repo);
      final input = find.byKey(const ValueKey('ai-planner-input'));
      await tester.enterText(input, '安排报告');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.enterText(input, '安排报告');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(repo.creates, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(tester.widget<TextField>(input).controller!.text, '安排报告\n');
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: desktopPlatforms,
  );

  testWidgets('mobile Enter does not send a multiline message', (tester) async {
    final repo = await pumpSheet(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '安排报告',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(repo.creates, 0);
  });

  testWidgets('a warning repeated by the service and draft is displayed once', (
    tester,
  ) async {
    final repo = FakePlannerRepository();
    repo.result = AiTurnResult(
      sessionId: repo.result.sessionId,
      draft: repo.result.draft,
      summary: repo.result.summary,
      questions: const [],
      warnings: const ['与午饭重叠'],
      quota: repo.result.quota,
    );
    await pumpSheet(tester, repository: repo);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '安排报告',
    );
    await tester.tap(find.byTooltip('生成安排'));
    await tester.pumpAndSettle();
    expect(find.text('与午饭重叠'), findsOneWidget);
  });
  testWidgets(
    'no-change reply finishes naturally without requesting more information',
    (tester) async {
      final repo = FakePlannerRepository();
      repo.result = AiTurnResult(
        sessionId: 'session-1',
        draft: const AiDraft(
          id: 'noop',
          status: 'pending',
          changes: [],
          warnings: [],
        ),
        summary: '好的，保持现有安排，不做调整。',
        questions: const [],
        warnings: const [],
        quota: repo.result.quota,
      );
      await pumpSheet(tester, repository: repo);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '不需要调整',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      expect(find.text('保持现有安排'), findsOneWidget);
      expect(find.text('先补充一点信息'), findsNothing);
      expect(find.text('应用安排'), findsNothing);
      expect(find.textContaining('想和你确认：'), findsNothing);
    },
  );

  testWidgets(
    'failed adjustment labels the preserved preview as the previous result',
    (tester) async {
      final repo = await pumpSheet(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '安排报告',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      repo.error = ApiException('失败', code: 'AI_PROPOSAL_INVALID');
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '保持不变',
      );
      await tester.tap(find.byTooltip('调整方案'));
      await tester.pumpAndSettle();
      expect(find.text('本次请求未完成，下方保留的是上一轮结果。'), findsOneWidget);
      expect(find.text('写报告'), findsOneWidget);
      expect(find.text('保持不变'), findsOneWidget);
    },
  );

  testWidgets(
    'rate-limit cooldown disables send until the provided wait has elapsed',
    (tester) async {
      final repo = FakePlannerRepository()
        ..error = ApiException(
          '频繁',
          code: 'AI_RATE_LIMITED',
          statusCode: 429,
          details: {'retryAfterSeconds': 3},
        );
      await pumpSheet(tester, repository: repo);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '保持今晚安排',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pump();
      expect(find.text('请等 3 秒后再继续，你输入的内容已保留。'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('voice appends to typed text and waits for explicit AI send', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'asr_consent_v1': true});
    final repo = FakePlannerRepository();
    final recorder = FakeRecorder();
    final voice = VoiceInput(
      recorder: recorder,
      transcribe: (_) async => '晚上跑步',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiPlannerSheet(repository: repo, voiceInput: voice),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '下午学习',
    );
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    recorder.stream.add(Uint8List(32000));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('结束录音'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(voice.state, VoiceState.idle, reason: voice.error);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-planner-input')))
          .controller!
          .text,
      '下午学习 晚上跑步',
    );
    expect(repo.creates, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    voice.dispose();
  });

  testWidgets('first use explains beta status and empty input stays local', (
    tester,
  ) async {
    final repo = await pumpSheet(tester, showIntro: true);
    expect(find.textContaining('测试阶段'), findsOneWidget);
    expect(find.textContaining('免费额度可能'), findsOneWidget);
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('生成安排'));
    await tester.pump();
    expect(find.text('请先描述你想安排的事情'), findsOneWidget);
    expect(repo.creates, 0);
    expect(find.byTooltip('语音输入'), findsOneWidget);
  });

  testWidgets('loading is visible and a failed request retains input', (
    tester,
  ) async {
    final repo = FakePlannerRepository()..pending = Completer<AiTurnResult>();
    await pumpSheet(tester, repository: repo);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '明天写报告',
    );
    await tester.tap(find.byTooltip('生成安排'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.pending!.completeError(ApiException('网络不好'));
    await tester.pumpAndSettle();
    expect(find.text('明天写报告'), findsOneWidget);
    expect(find.textContaining('网络不好'), findsOneWidget);
  });

  testWidgets('quota exhaustion has a clear message and retains input', (
    tester,
  ) async {
    final repo = FakePlannerRepository()
      ..error = ApiException('用完了', code: 'AI_QUOTA_EXHAUSTED');
    await pumpSheet(tester, repository: repo);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '安排今天',
    );
    await tester.tap(find.byTooltip('生成安排'));
    await tester.pumpAndSettle();
    expect(find.textContaining('今日免费额度已用完'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-planner-input')))
          .controller!
          .text,
      '安排今天',
    );
  });

  testWidgets(
    'proposal preview shows reason, before/after, warnings and replaces on adjustment',
    (tester) async {
      final repo = await pumpSheet(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '安排报告',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      expect(find.text('写报告'), findsOneWidget);
      expect(find.textContaining('优先处理'), findsOneWidget);
      expect(find.textContaining('未安排'), findsOneWidget);
      expect(find.textContaining('10:00'), findsOneWidget);
      expect(find.textContaining('与午饭重叠'), findsOneWidget);

      repo.result = sampleResult('draft-2', 750);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '晚一点',
      );
      await tester.tap(find.byTooltip('调整方案'));
      await tester.pumpAndSettle();
      expect(repo.turns, 1);
      expect(find.textContaining('12:30'), findsOneWidget);
      expect(find.textContaining('10:00'), findsNothing);
    },
  );

  testWidgets(
    'apply needs explicit confirmation and closing preserves session',
    (tester) async {
      var applied = 0;
      final repo = await pumpSheet(tester, onApplied: () => applied++);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '安排报告',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('应用安排'));
      await tester.tap(find.text('应用安排'));
      await tester.pumpAndSettle();
      expect(repo.applies, 0);
      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();
      expect(repo.applies, 1);
      expect(applied, 1);

      final discardRepo = await pumpSheet(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '安排报告',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(discardRepo.closes, 1);
      expect(discardRepo.deletes, 0);
    },
  );

  testWidgets('history restores a pending draft after the panel was closed', (
    tester,
  ) async {
    final now = DateTime.now();
    final repo = FakePlannerRepository();
    repo.history = [
      AiSessionSummary(
        id: 'saved-session',
        status: AiSessionStatus.closed,
        mode: 'hosted',
        firstMessage: '安排报告',
        summary: '报告安排已经准备好',
        hasPendingDraft: true,
        currentDraftId: 'draft-saved',
        createdAt: now,
        updatedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      ),
    ];
    final saved = sampleResult('draft-saved', 840);
    repo.detail = AiSessionDetail(
      id: 'saved-session',
      status: AiSessionStatus.closed,
      mode: 'hosted',
      startDate: now,
      endDate: now.add(const Duration(days: 7)),
      currentDraftId: 'draft-saved',
      createdAt: now,
      updatedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
      turns: [
        AiConversationTurn(
          id: 'turn-1',
          input: '安排报告',
          summary: saved.summary,
          questions: saved.questions,
          warnings: saved.warnings,
          draft: saved.draft,
          createdAt: now,
        ),
      ],
    );
    await pumpSheet(tester, repository: repo);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('历史记录'));
    await tester.pumpAndSettle();
    expect(find.text('安排报告'), findsOneWidget);
    expect(find.textContaining('等待你确认'), findsOneWidget);
    await tester.tap(find.text('安排报告'));
    await tester.pumpAndSettle();
    expect(find.textContaining('14:00'), findsOneWidget);
    expect(find.text('应用安排'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '晚一点',
    );
    await tester.tap(find.byTooltip('调整方案'));
    await tester.pumpAndSettle();
    expect(repo.turns, 1);
    expect(repo.creates, 0);
  });

  testWidgets('internal AI terms are replaced before display', (tester) async {
    final repo = FakePlannerRepository();
    repo.result = AiTurnResult(
      sessionId: repo.result.sessionId,
      draft: repo.result.draft,
      summary: 'schedule_task failed',
      questions: const ['taskId missing'],
      warnings: const ['JSON Schema invalid'],
      quota: repo.result.quota,
    );
    await pumpSheet(tester, repository: repo);
    await tester.enterText(
      find.byKey(const ValueKey('ai-planner-input')),
      '安排报告',
    );
    await tester.tap(find.byTooltip('生成安排'));
    await tester.pumpAndSettle();
    expect(find.textContaining('schedule_task'), findsNothing);
    expect(find.textContaining('taskId'), findsNothing);
    expect(find.textContaining('JSON Schema'), findsNothing);
  });
}
