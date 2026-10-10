import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';
import 'package:plan_app/widgets/ai_requirements_editor.dart';

import 'ai_planner_sheet_test.dart' show FakePlannerRepository, sampleResult;

class AdvancedFixture extends FakePlannerRepository
    implements AdvancedAiPlannerRepository {
  List<String>? selected;
  List<String>? confirmed;
  var undos = 0;
  bool remainder = true;
  Map<String, dynamic>? configuration;
  int? rangeDays;
  @override
  Future<Map<String, dynamic>> getOptions() async => {
    'revision': 'revision-1',
    'preferences': {'startMinute': 480, 'endMinute': 1320, 'breakMinutes': 15},
    'tasks': [
      {'id': 1, 'title': '合成任务'},
    ],
  };
  @override
  Future<AiTurnResult> generateConfigured(
    String message, {
    String? sessionId,
    required DateTime start,
    required DateTime end,
    required Map<String, dynamic> configuration,
  }) {
    this.configuration = configuration;
    rangeDays = end.difference(start).inDays;
    return sessionId == null
        ? createSession(message, start, end)
        : addTurn(sessionId, message);
  }

  @override
  Future<AiApplyResult> applySelected(
    String id,
    List<String> ids,
    List<String> requirementIds,
  ) async {
    selected = ids;
    confirmed = requirementIds;
    return AiApplyResult(
      applicationId: 'application-1',
      applied: ids.length,
      remainingDraft: remainder
          ? AiDraft(
              id: 'remaining',
              status: 'pending',
              changes: [result.draft.changes.last],
              warnings: const [],
            )
          : null,
    );
  }

  @override
  Future<void> undoApplication(String id) async {
    undos++;
  }
}

void main() {
  testWidgets(
    'new tasks show creation and estimated time before explicit confirmation',
    (tester) async {
      final repo = AdvancedFixture()..remainder = false;
      repo.result = repo.result.withDraft(
        AiDraft(
          id: 'new-task',
          status: 'pending',
          warnings: const [],
          changes: [
            AiDraftChange.fromJson({
              'id': 'new-change',
              'op': 'create_task',
              'title': '合成新作业',
              'date': '2026-10-17',
              'start': 600,
              'end': 660,
              'estimateMinutes': 60,
              'dueDate': null,
              'dueTime': null,
              'reason': '暂按一小时估算',
              'before': '新建任务',
            }),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AiPlannerSheet(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '帮我安排下周六的新作业',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      expect(repo.rangeDays, greaterThanOrEqualTo(12));
      expect(find.textContaining('确认后新建任务'), findsOneWidget);
      expect(find.textContaining('预计 60 分钟'), findsOneWidget);
      expect(repo.selected, isNull);
      await tester.tap(find.byKey(const ValueKey('ai-apply')));
      await tester.pumpAndSettle();
      expect(repo.selected, isNull);
      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();
      expect(repo.selected, ['new-change']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'task-specific windows stay separate from the daily planning window',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => AiRequirementsEditor(
                      options: {
                        'revision': 'new',
                        'preferences': {
                          'startMinute': 480,
                          'endMinute': 1320,
                          'breakMinutes': 15,
                        },
                        'tasks': [
                          {'id': 1, 'title': '合成任务'},
                        ],
                      },
                      requirements: const [
                        AiRequirement(
                          id: 'start',
                          kind: 'start_minute',
                          taskId: 1,
                          value: 1080,
                          source: '18点',
                        ),
                        AiRequirement(
                          id: 'end',
                          kind: 'end_minute',
                          taskId: 1,
                          value: 1140,
                          source: '19点',
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('22:00 结束'), findsOneWidget);
      expect(find.text('18:00开始'), findsOneWidget);
      await tester.tap(find.text('用于本次规划'));
      await tester.pumpAndSettle();
      final values = saved!['manualRequirements'] as List;
      expect(
        values.singleWhere(
          (r) => r['kind'] == 'end_minute' && r['taskId'] == null,
        )['value'],
        1320,
      );
      expect(
        values.singleWhere(
          (r) => r['kind'] == 'end_minute' && r['taskId'] == 1,
        )['value'],
        1140,
      );
    },
  );
  testWidgets(
    'reopening requirements keeps unsent settings and explicit exceptions',
    (tester) async {
      final repo = AdvancedFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AiPlannerSheet(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次要求'));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator).first).pop(
        <String, dynamic>{
          'manualRequirements': [
            {'kind': 'end_minute', 'taskId': null, 'value': 1200},
          ],
          'exceptions': [
            {'taskId': 1, 'kind': 'rest'},
          ],
          'exceptionsRevision': 'revision-1',
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次要求'));
      await tester.pumpAndSettle();
      final editor = tester.widget<AiRequirementsEditor>(
        find.byType(AiRequirementsEditor),
      );
      expect(editor.requirements.single.value, 1200);
      expect(editor.exceptions.single['kind'], 'rest');
      await tester.tap(find.text('用于本次规划'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次要求'));
      await tester.pumpAndSettle();
      expect(find.text('20:00 结束'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale exceptions are visible but must be explicitly checked again',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => AiRequirementsEditor(
                      options: {
                        'revision': 'new',
                        'preferences': {
                          'startMinute': 480,
                          'endMinute': 1320,
                          'breakMinutes': 15,
                        },
                        'tasks': [
                          {'id': 1, 'title': '合成任务'},
                        ],
                      },
                      requirements: const [],
                      exceptions: const [
                        {'taskId': 1, 'kind': 'rest'},
                      ],
                      exceptionsRevision: 'old',
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.textContaining('重新勾选'), findsOneWidget);
      await tester.ensureVisible(find.text('允许的冲突例外'));
      await tester.tap(find.text('允许的冲突例外'));
      await tester.pumpAndSettle();
      final tile = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '允许不留休息时间'),
      );
      expect(tile.value, false);
      await tester.tap(find.text('用于本次规划'));
      await tester.pumpAndSettle();
      expect(saved!['exceptions'], isEmpty);
    },
  );
  testWidgets(
    'editing requirements invalidates the old preview and only affects the next generation',
    (tester) async {
      final repo = AdvancedFixture();
      repo.result = repo.result.withDraft(
        const AiDraft(
          id: 'configured-draft',
          status: 'pending',
          warnings: [],
          changes: [
            AiDraftChange(
              id: 'configured-change',
              operation: 'schedule_task',
              title: '合成任务',
              date: '2026-10-09',
              start: 600,
              end: 660,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AiPlannerSheet(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '合成任务',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ai-apply')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('本次要求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用于本次规划'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ai-apply')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '按这些要求重新规划',
      );
      await tester.tap(find.byTooltip('调整方案'));
      await tester.pumpAndSettle();
      expect(repo.configuration!['manualRequirements'], hasLength(3));
      expect(repo.configuration!['exceptions'], isEmpty);
      expect(repo.configuration!['exceptionsRevision'], 'revision-1');
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'restored session keeps current remainder and source-backed requirements',
    () {
      final detail = AiSessionDetail.fromJson({
        'id': 'session',
        'status': 'active',
        'mode': 'hosted',
        'startDate': '2026-10-07',
        'endDate': '2026-10-10',
        'createdAt': 1,
        'updatedAt': 1,
        'expiresAt': 9999999999999,
        'turns': [],
        'currentDraft': {
          'id': 'remaining',
          'status': 'pending',
          'changes': [],
          'warnings': [],
        },
        'requirements': [
          {
            'id': 'fact',
            'kind': 'end_minute',
            'value': 1260,
            'source': '九点之前',
            'confirmed': false,
          },
        ],
        'applications': [
          {'id': 'applied', 'status': 'applied', 'created_at': 1},
        ],
        'exceptions': [
          {'taskId': 1, 'kind': 'rest'},
        ],
        'exceptionsRevision': 'revision-1',
        'exceptionsStale': true,
      });
      expect(detail.currentDraft!.id, 'remaining');
      expect(detail.requirements.single.source, '九点之前');
      expect(detail.applications.single.id, 'applied');
      expect(detail.exceptions.single['kind'], 'rest');
      expect(detail.exceptionsRevision, 'revision-1');
      expect(detail.exceptionsStale, true);
    },
  );
  testWidgets(
    'selection acknowledgement, remainder and undo stay in the same panel',
    (tester) async {
      final repo = AdvancedFixture();
      final original = sampleResult('full', 600);
      repo.result = AiTurnResult(
        sessionId: original.sessionId,
        draft: AiDraft(
          id: 'full',
          status: 'pending',
          warnings: const [],
          changes: const [
            AiDraftChange(
              id: 'first',
              operation: 'schedule_task',
              title: '合成任务甲',
              date: '2026-10-09',
              start: 600,
              end: 660,
            ),
            AiDraftChange(
              id: 'last',
              operation: 'schedule_task',
              title: '合成任务乙',
              date: '2026-10-09',
              start: 750,
              end: 810,
            ),
          ],
        ),
        summary: '合成方案',
        questions: const [],
        warnings: const [],
        quota: original.quota,
        requirements: const [
          AiRequirement(
            id: 'fact',
            kind: 'end_minute',
            value: 1260,
            source: '九点之前',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AiPlannerSheet(repository: repo)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '九点之前',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-select-last')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-apply')));
      await tester.tap(find.byKey(const ValueKey('ai-apply')));
      await tester.pumpAndSettle();
      expect(repo.selected, isNull);
      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();
      expect(repo.selected, ['first']);
      expect(repo.confirmed, ['fact']);
      expect(find.text('合成任务甲'), findsNothing);
      expect(find.text('合成任务乙'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-undo-application-1')),
      );
      await tester.tap(find.byKey(const ValueKey('ai-undo-application-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      expect(repo.undos, 1);
      expect(find.text('已撤销'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
