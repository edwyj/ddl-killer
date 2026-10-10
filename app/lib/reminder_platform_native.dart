import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

final _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;
Future<void> _init() async {
  if (_ready || !Platform.isAndroid) return;
  await _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_reminder'),
    ),
  );
  _ready = true;
}

const _details = NotificationDetails(
  android: AndroidNotificationDetails(
    'ddl_reminders',
    '任务提醒',
    channelDescription: '你设置的任务截止提醒',
    importance: Importance.high,
    priority: Priority.high,
    icon: 'ic_reminder',
  ),
);
Future<bool> requestNotificationPermission() async {
  if (!Platform.isAndroid) return false;
  await _init();
  final android = _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!;
  return await android.requestNotificationsPermission() == true;
}

Future<bool> requestPermission() async {
  if (!await requestNotificationPermission()) return false;
  final android = _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!;
  if (await android.canScheduleExactNotifications() != true) {
    await android.requestExactAlarmsPermission();
  }
  return await android.canScheduleExactNotifications() == true;
}

Future<void> activate(String token, String key) async {
  await (await SharedPreferences.getInstance()).setBool(
    'reminders_enabled',
    true,
  );
}

Future<bool> enabled() async {
  if (!Platform.isAndroid ||
      (await SharedPreferences.getInstance()).getBool('reminders_enabled') !=
          true) {
    return false;
  }
  await _init();
  final android = _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!;
  return await android.areNotificationsEnabled() == true &&
      await android.canScheduleExactNotifications() == true;
}

Future<void> synchronize(List<dynamic> tasks) async {
  await _init();
  final wanted = tasks.map((t) => t['id'] as int).toSet();
  for (final old in await _plugin.pendingNotificationRequests()) {
    if (old.id != 2147483646 && !wanted.contains(old.id)) {
      await _plugin.cancel(id: old.id);
    }
  }
  if (tasks.length > 400) throw StateError('提醒超过设备容量，请减少未来提醒数量');
  for (final task in tasks) {
    final when = DateTime.parse(task['reminder_at'] as String);
    if (!when.isAfter(DateTime.now())) continue;
    await _plugin.zonedSchedule(
      id: task['id'] as int,
      title: 'DDL Killer 提醒',
      body: task['title'] as String,
      scheduledDate: tz.TZDateTime.from(when, tz.UTC),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: '${task['id']}',
    );
  }
}

Future<void> clear(String? token) async {
  if (!Platform.isAndroid) return;
  await _init();
  await _plugin.cancelAll();
  await (await SharedPreferences.getInstance()).setBool(
    'reminders_enabled',
    false,
  );
}

Future<void> testNotification() async {
  await _init();
  await _plugin.zonedSchedule(
    id: 2147483646,
    title: 'DDL Killer 测试提醒',
    body: '系统定时通知已送达',
    scheduledDate: tz.TZDateTime.from(
      DateTime.now().add(const Duration(seconds: 10)),
      tz.UTC,
    ),
    notificationDetails: _details,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
  );
}
