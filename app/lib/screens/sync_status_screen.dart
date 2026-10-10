import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../auth_store.dart';
import '../reminders.dart';
import 'login_screen.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});
  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  final sync = Api.instance.offline;
  bool busy = false;
  String? message;
  String describe(dynamic value) {
    if (value == null) return '已删除或未设置';
    if (value is! Map) return value.toString();
    if (value.containsKey('courses'))
      return '课表：${(value['courses'] as List?)?.length ?? 0} 门课程';
    const labels = {
      'title': '标题',
      'name': '清单名',
      'notes': '备注',
      'done': '完成状态',
      'due_date': '截止日期',
      'due_time': '截止时间',
      'priority': '优先级',
      'reminder_at': '提醒时间',
      'schedule': '时间安排',
      'nickname': '昵称',
      'avatar': '头像',
      'hide_notification_content': '隐藏通知内容',
      'deleted_at': '删除状态',
      'list_id': '所属清单',
    };
    return value.entries
        .where((e) => labels.containsKey(e.key))
        .map((e) {
          var text = e.value?.toString() ?? '未设置';
          if (e.key == 'done')
            text = e.value == true || e.value == 1 ? '已完成' : '未完成';
          if (e.key == 'avatar') text = '已设置的头像';
          if (e.key == 'schedule' && e.value is Map) {
            final s = e.value as Map;
            String time(dynamic n) => n is int
                ? '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}'
                : '未设置';
            text = '${s['date']} ${time(s['start_min'])}–${time(s['end_min'])}';
          }
          if (e.key == 'list_id' && e.value != null) {
            final lists = sync.view['lists'] as List;
            text =
                lists
                    .cast<Map>()
                    .where((l) => l['id'] == e.value)
                    .firstOrNull?['name']
                    ?.toString() ??
                '清单已移除';
          }
          return '${labels[e.key]}：$text';
        })
        .join('\n');
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() async {
    await FilePicker.saveFile(
      dialogTitle: '保存本机数据',
      fileName: 'ddl-offline-recovery.json',
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(sync.exportPending())),
    );
    if (mounted) setState(() => message = '请确认文件已保存；文件包含本机完整数据和待同步修改，请妥善保管。');
  }

  Future<void> discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清除本机数据并退出？'),
        content: Text(
          '还有 ${sync.pendingCount} 项修改未同步。清除后无法恢复，请先确认恢复文件已保存。线上数据保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认放弃本机修改'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Api.instance.logout(discard: true);
    await AuthStore.clear();
    await Reminders.disable();
    Api.instance.token = null;
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('同步与离线数据')),
    body: ListenableBuilder(
      listenable: sync,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(sync.status, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            sync.persistent
                ? '内容先保存到本机，联网后自动同步。首次完整下载后，可离线查看和编辑；回收站和已完成内容仍遵循服务器保留期限。'
                : '公共设备模式：数据只保留在当前页面内，关闭后未同步修改会丢失，请离开前确认已同步。',
          ),
          const SizedBox(height: 12),
          Text('账号：${sync.username ?? ""} · 待同步 ${sync.pendingCount} 项'),
          if (sync.needsLogin)
            FilledButton(
              onPressed: busy
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    ),
              child: const Text('重新登录原账号'),
            ),
          OutlinedButton(
            onPressed: busy ? null : () => run(sync.sync),
            child: const Text('立即同步'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => run(export),
            child: const Text('导出本机数据与待同步修改'),
          ),
          if (sync.problem != null) ...[
            const Divider(),
            Text(
              sync.problem!['error'].toString(),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const Text('本机修改'),
            SelectableText(
              describe(
                (sync.problem!['body'] as Map).isEmpty
                    ? sync.problem!['base']
                    : sync.problem!['body'],
              ),
            ),
            const Text('线上当前内容'),
            SelectableText(describe(sync.problem!['conflict']?['current'])),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => run(() => sync.resolve(keepLocal: true)),
              child: const Text('保留我的修改并重新同步'),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => run(() => sync.resolve(keepLocal: false)),
              child: const Text('放弃这次修改，使用线上版本'),
            ),
          ],
          if (sync.pendingCount > 0)
            TextButton(
              onPressed: busy ? null : () => run(discard),
              child: const Text('放弃本机修改并退出'),
            ),
          if (message != null) Text(message!),
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}
