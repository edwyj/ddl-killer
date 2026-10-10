import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_updates.dart';
import '../build_channel.dart';
import '../api.dart';
import '../offline_platform.dart' as offline_platform;

Future<void> downloadUpdate(BuildContext context, AppRelease release) async {
  bool opened = false;
  try {
    opened = await launchUrl(
      release.downloadUrl,
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('无法打开更新链接，请稍后重试')));
  }
}

class UpdatePromptHost extends StatefulWidget {
  const UpdatePromptHost({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.updates,
    this.reloadWeb,
    this.pendingChanges,
  });
  final AppUpdates? updates;
  @visibleForTesting
  final Future<void> Function()? reloadWeb;
  @visibleForTesting
  final int Function()? pendingChanges;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost>
    with WidgetsBindingObserver {
  bool _checking = false, _prompting = false, _foreground = true;
  Timer? _timer;
  AppUpdates get updates => widget.updates ?? AppUpdates.instance;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    updates.addListener(_onUpdate);
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    updates.removeListener(_onUpdate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(UpdatePromptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      (oldWidget.updates ?? AppUpdates.instance).removeListener(_onUpdate);
      updates.addListener(_onUpdate);
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _check();
  }

  void _onUpdate() {
    if (!updates.checking && updates.available && _foreground) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  Future<void> _check() async {
    if (!mounted ||
        !_foreground ||
        _checking ||
        (!updates.isWeb && defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    _checking = true;
    try {
      await updates.check(minimumInterval: const Duration(minutes: 5));
      await _prompt();
    } catch (_) {
      /* Background checks must not interrupt editing. */
    } finally {
      _checking = false;
    }
  }

  Future<void> _prompt() async {
    if (!mounted ||
        !_foreground ||
        _prompting ||
        (!updates.isWeb && defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    _prompting = true;
    try {
      if (!mounted || !await updates.shouldPrompt()) return;
      if (!mounted || !_foreground) return;
      final context = widget.navigatorKey.currentState?.overlay?.context;
      if (context == null || !context.mounted) return;
      final release = updates.release!;
      updates.promptedBuild = release.build;
      updates.promptedRevision = release.webRevision;
      final update = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('发现新版本 ${release.version}'),
          content: SingleChildScrollView(
            child: Text(
              '${release.notes}\n\n${updates.isWeb
                  ? '更新会重新加载页面，你的数据会保留。'
                  : BuildChannel.beta
                  ? '会打开 Beta 下载页，登录后下载安装包。测试版数据与正式版独立。'
                  : '下载后由系统确认安装，可保留现有数据。'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('暂不更新'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(updates.isWeb ? '更新网页' : '立即更新'),
            ),
          ],
        ),
      );
      if (update == true) {
        if (context.mounted) {
          if (updates.isWeb) {
            final pending =
                widget.pendingChanges?.call() ??
                Api.instance.offline.pendingCount;
            if (pending > 0) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('请先同步本机修改，再更新网页')));
            } else {
              try {
                await (widget.reloadWeb ?? offline_platform.updateApp)();
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('更新尚未准备好，请稍后在「关于 DDL Killer」中重试'),
                    ),
                  );
                }
              }
            }
          } else {
            await downloadUpdate(context, release);
          }
        }
      } else {
        await updates.defer(release.build);
      }
    } catch (_) {
      /* A background update check must never interrupt task editing. */
    } finally {
      _prompting = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
