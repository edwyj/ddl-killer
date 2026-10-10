import 'package:flutter/material.dart';

import 'sync_status_screen.dart';
import '../offline_platform.dart' as offline_platform;
import 'reminder_settings_screen.dart';

import '../api.dart';
import '../auth_store.dart';
import '../plan_bus.dart';
import '../theme.dart';
import '../widgets/avatar_view.dart';
import 'about_screen.dart';
import 'email_account_screen.dart';
import 'mcp_connections_screen.dart';
import 'ai_settings_screen.dart';
import 'avatar_picker_screen.dart';
import 'change_password_screen.dart';
import 'login_screen.dart';
import 'nickname_screen.dart';
import 'schedule_import_screen.dart';
import 'security_settings_screen.dart';
import 'appearance_screen.dart';
import '../reminders.dart';
import '../community_state.dart';
import 'messages_screen.dart';
import 'feedback_screen.dart';
import 'referral_screen.dart';
import 'ai_invite_screen.dart';

/// 「我的」页：头像 / 昵称 / 真实统计 + 按用途分组的功能入口 + 退出登录。
/// 样式参考 TickTick 设置页，但不含任何商业化/社交项。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _username = '';
  String _nickname = '';
  String _avatar = '';
  bool _hasSchedule = false;
  Map<String, dynamic>? _emailStatus;

  /// `stats()` 的真实数据；拉取失败保持 null → 统计区整体隐藏。
  Map<String, dynamic>? _stats;

  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    Api.instance.emailRevision.addListener(_emailChanged);
    // 其它面板增删任务后，统计也要跟着变（IndexedStack 常驻，切页不会重新 init）
    PlanBus.instance.revision.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    PlanBus.instance.revision.removeListener(_onDataChanged);
    Api.instance.emailRevision.removeListener(_emailChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) _loadStats();
  }

  void _emailChanged() {
    if (mounted) _loadEmail();
  }

  Future<void> _refresh() async {
    await Future.wait([_loadProfile(), _loadStats(), _loadEmail()]);
  }

  Future<void> _loadEmail() async {
    try {
      final r = await Api.instance.accountEmail();
      if (mounted) setState(() => _emailStatus = r);
    } catch (_) {}
  }

  Future<void> _openEmail() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EmailAccountScreen()),
    );
    if (mounted) await _loadEmail();
  }

  Future<void> _loadProfile() async {
    try {
      final m = await Api.instance.me();
      if (!mounted) return;
      setState(() {
        _username = m.username;
        _nickname = m.nickname;
        _avatar = m.avatar;
        _hasSchedule = m.hasSchedule;
        _error = null;
      });
    } catch (_) {
      // 离线时保留既有内容，只在头部提示可下拉重试，不阻塞整页
      if (mounted) setState(() => _error = '资料加载失败，下拉可重试');
    }
  }

  Future<void> _loadStats() async {
    try {
      final s = await Api.instance.stats();
      if (!mounted) return;
      setState(() => _stats = s);
    } catch (_) {
      // 统计不是关键路径：失败就整块隐藏，绝不显示假数字
      if (mounted) setState(() => _stats = null);
    }
  }

  Future<void> _logout() async {
    try {
      await Api.instance.logout();
    } on ApiException catch (e) {
      if (e.code != 'SESSION_INVALID') {
        _toast('退出未完成：${e.message}');
        return;
      }
    } catch (_) {
      _toast('退出未完成，请联网后重试');
      return;
    }
    Api.instance.network.reset();
    await Api.instance.offline.clear();
    await Reminders.disable();
    await AuthStore.clear();
    // 内存里的 token 也要清：只清盘上的，退出后本会话仍能带着旧 token 直连后端
    Api.instance.token = null;
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 传给头像选择器的 "current"。
  /// pickAvatar 的签名(frozen)只有 current、没有 username，首次设置头像的人
  /// 拿不到"当前首字"，所以在调用方合成一个默认 spec(种子色 + 用户名首字)，
  /// 让选择器的字符框预填首字，而不是空着让人对着保存按钮猜。
  String get _pickerSeed {
    if (_avatar.isNotEmpty) return _avatar;
    if (_username.isEmpty) return ''; // 资料还没加载出来，合成不了
    return 'preset:${AvatarView.hexOf(seed)}:${AvatarView.initialOf(_username)}';
  }

  /// 头像：选择 → 保存 → 立即回显 → 以服务端为准刷新。
  Future<void> _changeAvatar() async {
    final spec = await pickAvatar(context, current: _pickerSeed);
    if (spec == null || !mounted) return; // null = 取消
    try {
      await Api.instance.updateProfile(avatar: spec);
      if (!mounted) return;
      setState(() => _avatar = spec);
      _toast('头像已更新');
      await _loadProfile();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('保存失败，请检查网络');
    }
  }

  Future<void> _changeNickname() async {
    final v = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NicknameScreen(current: _nickname)),
    );
    if (v == null || !mounted) return;
    setState(() => _nickname = v);
    _toast(v.isEmpty ? '昵称已清除' : '昵称已更新');
    await _loadProfile();
  }

  static String _modeLabel(ThemeMode m) => switch (m) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色',
    ThemeMode.dark => '深色',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            _headerCard(theme),
            const SizedBox(height: 4),
            if (_emailStatus?['bound'] == false)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Card(
                  color: theme.colorScheme.primaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.alternate_email),
                    title: const Text('给账号留一份安心'),
                    subtitle: const Text('绑定常用邮箱，忘记密码时也能找回来。'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openEmail,
                  ),
                ),
              ),
            _section('账号与安全', [
              _row(
                Icons.badge_outlined,
                '修改昵称',
                onTap: _changeNickname,
                subtitle: _nickname.isEmpty ? '未设置' : _nickname,
              ),
              _row(
                Icons.lock_outline,
                '修改密码',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ChangePasswordScreen(),
                  ),
                ),
              ),
              _row(
                Icons.alternate_email,
                '邮箱',
                subtitle: _emailStatus == null
                    ? '绑定后可找回密码'
                    : _emailStatus!['bound'] == true
                    ? _emailStatus!['masked_email'] as String
                    : '未绑定 · 绑定后可找回密码',
                onTap: _openEmail,
              ),
              _row(
                Icons.shield_outlined,
                '安全与隐私',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SecuritySettingsScreen(),
                  ),
                ),
              ),
            ]),
            _section('计划与工具', [
              _row(
                Icons.calendar_month_outlined,
                '导入课表',
                // 导入页成功时 pop(true)。本页常驻 IndexedStack、不会重 init，
                // 拿到 true 必须主动 _refresh() 一次，否则行副标题与统计胶囊保持旧值。
                onTap: () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const ScheduleImportScreen(),
                    ),
                  );
                  if (ok == true && mounted) await _refresh();
                },
                subtitle: _hasSchedule ? '已导入' : '未导入',
              ),
              _row(
                Icons.notifications_outlined,
                '任务提醒',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ReminderSettingsScreen(),
                  ),
                ),
              ),
              _row(
                Icons.auto_awesome_outlined,
                'AI 计划助手设置',
                subtitle: '官方体验额度与自己的 API Key',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
                ),
              ),
              _row(
                Icons.hub_outlined,
                '智能体连接',
                subtitle: '管理 MCP 授权与手动令牌',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const McpConnectionsScreen(),
                  ),
                ),
              ),
            ]),
            _section('外观与数据', [
              ListTile(
                leading: Icon(
                  Icons.dark_mode_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('外观'),
                subtitle: ListenableBuilder(
                  listenable: Listenable.merge([
                    ThemeController.mode,
                    ThemeController.palette,
                  ]),
                  builder: (_, __) => Text(
                    '${_modeLabel(ThemeController.mode.value)} · ${ThemeController.palette.value.label}',
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AppearanceScreen()),
                ),
              ),
              ListenableBuilder(
                listenable: Api.instance.offline,
                builder: (context, _) => _row(
                  Icons.cloud_sync_outlined,
                  '同步与离线数据',
                  subtitle:
                      '${Api.instance.offline.status}${offline_platform.shellReady ? "" : " · 网页离线资源准备中"}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SyncStatusScreen()),
                  ),
                ),
              ),
            ]),
            _section('消息与反馈', [
              ListenableBuilder(
                listenable: communityState,
                builder: (context, _) => _row(
                  Icons.mail_outline,
                  '消息',
                  subtitle: communityState.unread > 0
                      ? '${communityState.unread} 条未读'
                      : null,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MessagesScreen()),
                  ),
                ),
              ),
              _row(
                Icons.chat_bubble_outline,
                '问题与建议',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const FeedbackScreen()),
                ),
              ),
            ]),
            _section('邀请与奖励', [
              _row(
                Icons.group_add_outlined,
                '邀请朋友',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReferralScreen()),
                ),
              ),
              _row(
                Icons.redeem_outlined,
                '兑换码',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiInviteScreen()),
                ),
              ),
            ]),
            _section('', [
              _row(
                Icons.info_outline,
                '关于 DDL Killer',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AboutScreen())),
                subtitle: '版本 ${AboutScreen.version}',
              ),
            ]),
            const SizedBox(height: 20),
            // 退出登录（红色，参考图为白底红字卡片）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: TextButton(
                    onPressed: _logout,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '退出登录',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部个人卡：大头像(+改头像角标) + 用户名/昵称 + 统计胶囊。
  Widget _headerCard(ThemeData theme) {
    final hasNick = _nickname.isNotEmpty;
    final title = hasNick
        ? _nickname
        : (_username.isEmpty ? '加载中…' : _username);
    final subtitle =
        _error ??
        (hasNick ? '@$_username' : (_username.isEmpty ? '' : '未设置昵称'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        child: InkWell(
          key: const ValueKey('profile-header'),
          borderRadius: BorderRadius.circular(12),
          onTap: _changeAvatar,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 10, 16),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AvatarView(avatar: _avatar, username: _username, size: 68),
                    // 改头像角标（编辑提示，非商业徽章）
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.cardColor, width: 2),
                        ),
                        child: const Icon(
                          Icons.photo_camera,
                          size: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: _error != null
                                ? theme.colorScheme.error
                                : theme.colorScheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      // 空 map 也不渲染：宁可没有统计，也不显示四个 0 的假数据
                      if (_stats != null && _stats!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _statsPills(theme),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: theme.colorScheme.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 统计胶囊：只用 `stats()` 的真实数字（清单/待办/已完成/课程）。
  Widget _statsPills(ThemeData theme) {
    final s = _stats;
    if (s == null || s.isEmpty) return const SizedBox.shrink();
    // 契约保证是整数；这里只做防御，避免脏数据在 build 里抛 TypeError 变红屏
    int n(String k) {
      final v = s[k];
      return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    }

    final items = <(String, int)>[
      ('清单', n('lists')),
      ('待办', n('todos')),
      ('已完成', n('done')),
      ('课程', n('courses')),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (label, value) in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$label $value',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          Card(child: Column(children: rows)),
        ],
      ),
    );
  }

  Widget _row(
    IconData icon,
    String label, {
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
