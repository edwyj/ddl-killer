import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models/ai_planner.dart';

void main() {
  test('parses AI session summaries and keeps pending-draft metadata', () {
    final session = AiSessionSummary.fromJson({
      'id': 'session-1',
      'status': 'closed',
      'mode': 'hosted',
      'firstMessage': '帮我安排复习',
      'summary': '已经整理好复习安排',
      'hasPendingDraft': true,
      'currentDraftId': 'draft-1',
      'createdAt': 1720000000000,
      'updatedAt': 1720000001000,
      'expiresAt': 1720000002000,
    });

    expect(session.status, AiSessionStatus.closed);
    expect(session.firstMessage, '帮我安排复习');
    expect(session.hasPendingDraft, isTrue);
    expect(session.currentDraftId, 'draft-1');
    expect(session.updatedAt.millisecondsSinceEpoch, 1720000001000);
  });

  test('parses session detail including conversation turns and drafts', () {
    final session = AiSessionDetail.fromJson({
      'id': 'session-1',
      'status': 'active',
      'mode': 'byok',
      'startDate': '2026-09-28',
      'endDate': '2026-10-05',
      'currentDraftId': 'draft-1',
      'createdAt': 1720000000000,
      'updatedAt': 1720000001000,
      'expiresAt': 1720000002000,
      'turns': [
        {
          'id': 'turn-1',
          'input': '周三前完成',
          'proposal': {
            'summary': '已经为你留出时间',
            'questions': ['晚上可以吗？'],
            'warnings': [],
          },
          'draft': {
            'id': 'draft-1',
            'status': 'pending',
            'changes': [],
            'warnings': [],
          },
          'createdAt': 1720000000500,
        },
      ],
    });

    expect(session.status, AiSessionStatus.active);
    expect(session.turns, hasLength(1));
    expect(session.turns.single.input, '周三前完成');
    expect(session.turns.single.summary, '已经为你留出时间');
    expect(session.turns.single.questions, ['晚上可以吗？']);
    expect(session.turns.single.draft?.id, 'draft-1');
  });

  test('unknown session status degrades safely to expired', () {
    expect(AiSessionStatusX.fromWire('future_status'), AiSessionStatus.expired);
  });
}
