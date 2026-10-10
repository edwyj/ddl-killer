import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reminder_platform.dart' as platform;

/// Device-wide introduction. No permission request happens before consent.
class PermissionIntroHost extends StatefulWidget {
  const PermissionIntroHost({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.requestNotifications = platform.requestNotificationPermission,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final Future<bool> Function() requestNotifications;
  @override
  State<PermissionIntroHost> createState() => _PermissionIntroHostState();
}

class _PermissionIntroHostState extends State<PermissionIntroHost> {
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _introduce());
    }
  }

  Future<void> _introduce() async {
    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
      if (preferences.getBool('permission_intro_v1') == true) return;
    } catch (_) {
      /* A storage failure must not block access. */
    }
    if (!mounted) return;
    final context = widget.navigatorKey.currentState?.overlay?.context;
    if (context == null || !context.mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('先说清楚权限'),
        content: const SingleChildScrollView(
          child: Text(
            '通知用于任务提醒，你可以选择允许，也可以以后在「我的 → 任务提醒」开启。准时提醒需要的“闹钟和提醒”，会在开启该功能时再申请。\n\n'
            '麦克风只在你使用语音输入时申请，录音会发送至硅基流动识别。导入课表、上传附件和选择头像通过系统文件选择器完成，无需读取整个存储空间。\n\n'
            '我们不申请定位、相机或通讯录权限。拒绝通知或麦克风，仍可使用清单、日历和文字输入。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不开启'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('允许通知'),
          ),
        ],
      ),
    );
    try {
      await preferences?.setBool('permission_intro_v1', true);
    } catch (_) {}
    if (allow != true || !mounted) return;
    try {
      await widget.requestNotifications();
    } catch (_) {
      /* Denial does not block the app. */
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
