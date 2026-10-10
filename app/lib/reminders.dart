import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'reminder_platform.dart' as platform;

class Reminders {
  static final status = ValueNotifier<String>('本设备尚未开启提醒');
  static Future<void> _queue = Future.value();
  static Future<void> sync() {
    _queue = _queue.catchError((_) {}).then((_) async {
      final token = Api.instance.token;
      if (token == null) return;
      try {
        if (!await platform.enabled()) { status.value = '本设备尚未开启提醒，或系统权限未允许'; return; }
        final tasks = await Api.instance.reminders();
        if (token != Api.instance.token) return;
        await platform.synchronize(tasks);
        status.value = kIsWeb ? '浏览器推送已开启 · ${tasks.length} 个待提醒任务' : '已同步 ${tasks.length} 个系统提醒';
      } catch (_) { status.value = '提醒同步失败，请联网后重试；之前已设的提醒可能未更新'; }
    });
    return _queue;
  }
  static Future<void> enable() async {
    try {
      if (!await platform.requestPermission()) {
        status.value = '未开启：请允许通知；安卓还需允许“闹钟和提醒”'; return;
      }
      final token = Api.instance.token;
      if (token == null) return;
      final key = kIsWeb ? await Api.instance.pushKey() : '';
      if (token != Api.instance.token) return;
      await platform.activate(token,key);
      await sync();
    } catch (_) { status.value = '开启失败，请检查通知权限与网络后重试'; }
  }
  static Future<void> disable([String? oldToken]) {
    _queue = _queue.catchError((_) {}).then((_) async {
      try { await platform.clear(oldToken ?? Api.instance.token); status.value = '本设备提醒已关闭'; }
      catch (_) { status.value = '提醒关闭未完成，请重试'; }
    });
    return _queue;
  }
  static Future<void> test() async {
    try {
      if (!await platform.enabled()) { status.value = '请先开启本设备提醒'; return; }
      await platform.testNotification();
      status.value = kIsWeb ? '已发送本地测试通知，请查看系统通知中心' : '10 秒后发送测试提醒，可锁屏检查';
    } catch (_) { status.value = '测试提醒未能设置，请检查系统通知权限'; }
  }
}
