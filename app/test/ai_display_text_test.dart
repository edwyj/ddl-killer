import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/ai_display_text.dart';

void main() {
  test('operation and status codes have natural Chinese labels', () {
    expect(aiOperationLabel('schedule_task'), '安排任务');
    expect(aiOperationLabel('unschedule_task'), '取消原安排');
    expect(aiOperationLabel('create_block'), '新建时间段');
    expect(aiOperationLabel('something_new'), '调整安排');
    expect(aiDraftStatusLabel('pending'), '等待确认');
    expect(aiDraftStatusLabel('applied'), '已应用');
    expect(aiDraftStatusLabel('discarded'), '已被新方案替代');
    expect(aiDraftStatusLabel('expired'), '已过期');
  });

  test('warning codes have helpful user-facing messages', () {
    expect(aiWarningText('COURSE_CONFLICT'), '与课程时间冲突');
    expect(aiWarningText('TIME_OVERLAP'), '与已有安排重叠');
    expect(aiWarningText('DRAFT_STALE'), '任务已经发生变化，请重新生成安排');
    expect(aiWarningText('UNKNOWN'), '这份安排需要再确认一下');
  });

  test('internal implementation terms never reach visible copy', () {
    const unsafe = [
      'schedule_task failed',
      'unschedule_task',
      'create_block',
      'DRAFT_STALE',
      'taskId is missing',
      'JSON Schema invalid',
    ];
    for (final value in unsafe) {
      final shown = aiSafeText(value, fallback: '我需要重新整理一下这份安排。');
      expect(shown, '我需要重新整理一下这份安排。');
      expect(
        shown,
        isNot(contains(RegExp(r'schedule_task|taskId|JSON Schema'))),
      );
    }
    expect(aiSafeText('我已经为你整理好安排。'), '我已经为你整理好安排。');
  });

  test('AI error codes become calm actionable messages', () {
    expect(aiErrorText('DRAFT_STALE', 'DRAFT_STALE'), '任务已经发生变化，请重新生成安排');
    expect(
      aiErrorText('AI_SESSION_EXPIRED', 'expired'),
      '这次对话已保存到历史记录，你可以重新生成一份安排',
    );
    expect(aiErrorText(null, '网络不好'), '网络不好');
  });
}
