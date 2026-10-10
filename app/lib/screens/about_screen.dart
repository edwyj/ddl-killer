import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../build_channel.dart';
import '../app_updates.dart';
import '../api.dart';
import '../offline_platform.dart' as offline_platform;
import '../widgets/app_logo.dart';
import '../widgets/update_prompt_host.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.updates});
  final AppUpdates? updates;
  static const String version = AppVersion.displayName;
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final AppUpdates updates;
  bool _updating = false;
  @override
  void initState() {
    super.initState();
    updates = widget.updates ?? AppUpdates.instance;
    updates.check();
  }

  Future<void> _update() async {
    if (_updating) return;
    if (kIsWeb && Api.instance.offline.pendingCount > 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先同步本机修改，再更新网页')));
      return;
    }
    setState(() => _updating = true);
    try {
      if (kIsWeb) {
        await offline_platform.updateApp();
      } else {
        await downloadUpdate(context, updates.release!);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('更新尚未准备好，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _open(String path) async {
    var ok = false;
    try {
      ok = await launchUrl(
        path == '/download.html'
            ? BuildChannel.downloadPage
            : Uri.https('ddlkiller.com', path),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开链接，请访问 ddlkiller.com')));
    }
  }

  Future<void> _copyDiagnostic() async {
    await Clipboard.setData(
      ClipboardData(
        text:
            'DDL Killer ${AppVersion.displayName}+${AppVersion.build}\n${kIsWeb ? 'Web' : defaultTargetPlatform.name}\n${updates.diagnostic}',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制检查信息，可发给开发者排查')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('关于 DDL Killer', style: theme.textTheme.titleLarge),
      ),
      body: ListenableBuilder(
        listenable: updates,
        builder: (context, _) {
          final latest = updates.release;
          final useRemote =
              latest != null &&
              latest.build >= updates.installed.build &&
              latest.notes.trim().isNotEmpty;
          final notes = useRemote ? latest.notes : AppVersion.notes;
          final version = useRemote ? latest.version : AppVersion.displayName;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 580),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    const Center(child: AppLogo(size: 68)),
                    const SizedBox(height: 14),
                    Text(
                      'DDL Killer',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '版本 ${AboutScreen.version}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '让想做的事，拥有自己的时间。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  updates.checking
                                      ? Icons.sync
                                      : updates.available
                                      ? Icons.system_update_alt
                                      : updates.error != null
                                      ? Icons.wifi_off_outlined
                                      : Icons.check_circle_outline,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    updates.status,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            if (updates.checking) ...[
                              const SizedBox(height: 12),
                              const LinearProgressIndicator(minHeight: 2),
                            ],
                            if (updates.error != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                updates.error!,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            if (updates.available)
                              FilledButton.icon(
                                onPressed: _updating || updates.checking
                                    ? null
                                    : _update,
                                icon: const Icon(Icons.system_update_alt),
                                label: Text(
                                  _updating
                                      ? '正在准备更新…'
                                      : kIsWeb
                                      ? '加载新版本'
                                      : '更新到 ${updates.release!.version}',
                                ),
                              ),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: updates.checking
                                      ? null
                                      : () => updates.check(force: true),
                                  child: const Text('检查更新'),
                                ),
                                if (updates.error != null) ...[
                                  TextButton(
                                    onPressed: () => _open('/download.html'),
                                    child: const Text('官网下载'),
                                  ),
                                  TextButton(
                                    onPressed: _copyDiagnostic,
                                    child: const Text('复制检查信息'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '最新版本变化',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            version,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          notes,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.7,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Card(
                      child: Column(
                        children: [
                          _link('官方网站', 'ddlkiller.com', Icons.language, '/'),
                          _link('使用帮助', null, Icons.help_outline, '/help.html'),
                          _link(
                            '隐私说明',
                            null,
                            Icons.privacy_tip_outlined,
                            '/privacy.html',
                          ),
                          if (kIsWeb)
                            _link(
                              '下载 Android 版',
                              null,
                              Icons.android,
                              '/download.html',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _link(String title, String? subtitle, IconData icon, String path) =>
      ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: () => _open(path),
      );
}
