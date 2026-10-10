import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../reminders.dart';
import '../api.dart';

class ReminderSettingsScreen extends StatefulWidget {
  const ReminderSettingsScreen({super.key});
  @override
  State<ReminderSettingsScreen> createState() => _ReminderSettingsState();
}

class _ReminderSettingsState extends State<ReminderSettingsScreen> {
  bool? _hide;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await Api.instance.hideNotificationContent();
      if (mounted) setState(() => _hide = value);
    } catch (_) {
      if (mounted) setState(() => _error = '隐私设置读取失败，请重新进入此页重试');
    }
  }

  Future<void> _set(bool value) async {
    setState(() => _saving = true);
    try {
      await Api.instance.setHideNotificationContent(value);
      await Reminders.sync();
      if (mounted) setState(() => _hide = value);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请联网后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('任务提醒')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('提醒设置保存在任务中，每台设备需要分别开启通知。'),
        const SizedBox(height: 12),
        const Text('点击开启时才申请权限：通知用于显示提醒；安卓的“闹钟和提醒”用于准时触发。拒绝授权仍可正常使用清单和日历。'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('隐藏通知中的任务内容'),
          subtitle: const Text('默认开启，仅显示通用提醒。其他安卓设备需联网打开应用才能更新已设通知。'),
          value: _hide ?? true,
          onChanged: _hide == null || _saving ? null : _set,
        ),
        if (_error != null) Text(_error!),
        const SizedBox(height: 20),
        ValueListenableBuilder<String>(
          valueListenable: Reminders.status,
          builder: (_, value, _) => Text(value),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: Reminders.enable,
          child: const Text('开启 / 检查权限'),
        ),
        OutlinedButton(onPressed: Reminders.sync, child: const Text('重新同步提醒')),
        OutlinedButton(onPressed: Reminders.test, child: const Text('发送测试提醒')),
        TextButton(onPressed: Reminders.disable, child: const Text('关闭本设备提醒')),
        const SizedBox(height: 16),
        Text(
          kIsWeb ? '网页关闭后由浏览器接收推送，需要浏览器和系统允许后台通知，并能连接推送服务。' : '已同步的提醒交给安卓系统，关闭应用后也可触发。请允许通知、闹钟和提醒；部分手机还需允许后台运行。其他设备修改任务后，请打开本应用同步，才能更新本机已设的提醒。',
        ),
      ],
    ),
  );
}
