import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../api.dart';
import '../auth_store.dart';
import '../reminders.dart';
import 'login_screen.dart';
import '../widgets/secret_text_field.dart';

class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});
  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  bool _busy = false;
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is ApiException ? e.message : '操作未完成，请检查网络后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    await Api.instance.offline.clear();
    Api.instance.token = null;
    await Api.instance.network.clearCache();
    await Reminders.disable();
    await AuthStore.clear();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  Future<({String password, String confirmation})?> _confirm({
    required bool deleting,
  }) async {
    final password = TextEditingController(),
        confirmation = TextEditingController();
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(deleting ? '永久注销账号' : '导出我的数据'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                deleting
                    ? '将永久删除账号、所有清单、任务、课表和推送订阅，无法撤销。已有备份按保留期限到期清理；请先导出需要的资料。'
                    : '导出包含个人资料、任务和课表，请妥善保管文件。为确认是本人操作，请输入当前密码。',
              ),
              const SizedBox(height: 12),
              SecretTextField(
                controller: password,
                labelText: '当前密码',
                border: const UnderlineInputBorder(),
              ),
              if (deleting)
                TextField(
                  controller: confirmation,
                  decoration: const InputDecoration(labelText: '输入“删除我的账号”'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(deleting ? '确认注销' : '导出'),
          ),
        ],
      ),
    );
    final result = answer == true
        ? (password: password.text, confirmation: confirmation.text)
        : null;
    // Dialog fields finish their exit animation before their controllers are disposed.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    password.dispose();
    confirmation.dispose();
    return result;
  }

  Future<void> _export() async {
    final answer = await _confirm(deleting: false);
    if (answer == null || !mounted) return;
    await _run(() async {
      final session = Api.instance.token;
      final data = await Api.instance.exportAccount(answer.password);
      if (session != Api.instance.token) return;
      final result = await FilePicker.saveFile(
        dialogTitle: '保存我的数据',
        fileName: 'ddl-killer-export.json',
        mimeType: 'application/json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
        ),
      );
      if (mounted) {
        setState(
          () =>
              _message = result == null ? '已关闭保存窗口；浏览器请查看下载记录' : '数据已导出，请妥善保管',
        );
      }
    });
  }

  Future<void> _delete() async {
    final answer = await _confirm(deleting: true);
    if (answer == null || !mounted) return;
    if (answer.confirmation != '删除我的账号') {
      setState(() => _message = '请输入“删除我的账号”确认');
      return;
    }
    await _run(() async {
      await Reminders.disable();
      await Api.instance.deleteAccount(answer.password, answer.confirmation);
      await _leave();
    });
  }

  Future<void> _logoutAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出所有设备？'),
        content: const Text(
          '包括当前设备。其他设备需重新登录，浏览器推送订阅将关闭。离线安卓设备原有提醒要在该设备联网打开后才会清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('全部退出'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _run(() async {
        await Reminders.disable();
        await Api.instance.logout(all: true);
        await _leave();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安全与隐私')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '你的数据与权限',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          '我们保存你主动填写的账号资料、已验证的邮箱、任务、清单、课表和提醒设置，用于登录、跨设备同步和提醒。邮箱用于验证、找回密码和安全变更通知；邮件通过腾讯云邮件推送服务发送，服务商会处理收件地址和邮件内容，不用于推广。密码保存为不可直接还原的哈希；服务端仍能处理任务内容，这不是端到端加密。',
        ),
        const SizedBox(height: 12),
        const Text(
          '网页登录凭据由安全 Cookie 管理，任务等离线数据保存在浏览器数据库中；公共设备可在登录时关闭持久保存。安卓登录凭据由系统密钥保护，离线数据保存在应用私有空间。登录失效会保留本机修改，主动退出时清除；有待同步内容时需先处理。',
        ),
        const SizedBox(height: 12),
        const Text(
          '安卓首次进入会说明权限用途，由你选择是否允许通知；闹钟权限在开启准时提醒时申请。麦克风仅在首次使用语音输入时申请，录音发送至硅基流动识别，不永久保存。拒绝授权不影响清单、日历和文字输入。浏览器通知在主动开启提醒时申请。',
        ),
        const SizedBox(height: 12),
        const Text(
          '不申请定位、相机、通讯录或整盘存储权限。头像、课表和反馈附件通过系统选择器读取你选中的文件；缓存位于应用私有空间。联网用于账号和数据同步，振动用于提醒；开机接收器仅恢复你已开启的任务提醒。你提交的反馈和附件会交给我们处理，用于回复和完善功能。',
        ),
        const SizedBox(height: 12),
        const Text(
          '回收站任务保留 7 天，已完成任务按当前规则保留 3 天后永久清理。注销会删除在线数据；历史备份在其保留期限内可能仍有副本。导出的文件由你自行保管。',
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await Api.instance.logout();
                  await _leave();
                }),
          child: const Text('清除本机数据与提醒并退出'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : _export,
          child: const Text('导出我的数据'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : _logoutAll,
          child: const Text('退出所有设备'),
        ),
        TextButton(
          onPressed: _busy ? null : _delete,
          child: const Text('永久注销账号'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message!),
          ),
      ],
    ),
  );
}
