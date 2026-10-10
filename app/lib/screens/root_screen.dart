import 'package:flutter/material.dart';

import 'dart:async';

import '../reminders.dart';

import '../api.dart';
import '../plan_bus.dart';
import 'week_screen.dart';
import 'list_screen.dart';
import 'ddl_screen.dart';
import 'settings_screen.dart';
import 'sync_status_screen.dart';
import 'ai_planner_sheet.dart';
import '../widgets/sync_notice.dart';
import '../widgets/ai_ribbon.dart';
import '../ai_ribbon_preferences.dart';
import '../ai_assistant_state.dart';
import '../community_state.dart';
import '../build_channel.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'email_account_screen.dart';

/// 底部标签导航(只显图标，labelBehavior: alwaysHide)：
/// 清单(ListScreen) / 任务视图(WeekScreen) / DDL(DdlScreen) / 我的(SettingsScreen)
/// 第 4 个 tab 承载个人资料与设置，其 AppBar 标题即「我的」。
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with WidgetsBindingObserver {
  Timer? _reminderTimer;
  Timer? _messageTimer;
  int _tab = 0;
  AiRibbonPreferences? _ribbonPreferences;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Api.instance.offline.start();
    Reminders.sync();
    _reminderTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => Reminders.sync(),
    );
    PlanBus.instance.revision.addListener(_onDataChanged);
    _ribbonPreferences = aiAssistantState.featureEnabled == false
        ? null
        : AiRibbonPreferences.current;
    aiAssistantState.addListener(_aiAvailabilityChanged);
    _loadAiAvailability();
    unawaited(_loadMessages());
    unawaited(_remindEmailBinding());
    _messageTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(communityState.refreshMessages());
      }
    });
    communityState.addListener(_messagesChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reminderTimer?.cancel();
    _messageTimer?.cancel();
    communityState.removeListener(_messagesChanged);
    PlanBus.instance.revision.removeListener(_onDataChanged);
    aiAssistantState.removeListener(_aiAvailabilityChanged);
    super.dispose();
  }

  Future<void> _remindEmailBinding() async {
    final uid = Api.instance.offline.uid;
    if (uid == null) return;
    final key =
        'email-binding-reminder-v1:${BuildChannel.beta ? 'beta' : 'stable'}:$uid';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) == true) return;
      final status = await Api.instance.accountEmail();
      if (!mounted ||
          uid != Api.instance.offline.uid ||
          status['enabled'] != true ||
          status['bound'] == true) {
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('给账号留一份安心：绑定邮箱，忘记密码也能找回来。'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: '去绑定',
            onPressed: () {
              if (!mounted || uid != Api.instance.offline.uid) return;
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EmailAccountScreen()),
              );
            },
          ),
        ),
      );
      await prefs.setBool(key, true);
    } catch (_) {
      // Offline or unavailable mail service must not interrupt normal use.
    }
  }

  Future<void> _loadMessages() async {
    await communityState.attach(
      Api.instance.offline.uid,
      persistent: Api.instance.offline.persistent,
    );
    await communityState.refreshMessages();
  }

  void _messagesChanged() {
    if (mounted) setState(() {});
  }

  /// 数据改变后同步本机提醒。
  void _onDataChanged() {
    Reminders.sync();
  }

  Future<void> _loadAiAvailability() async {
    try {
      await aiAssistantState.preload(Api.instance.offline.uid);
      final preferences = await AiRibbonPreferences.shared();
      if (mounted && aiAssistantState.featureEnabled != false) {
        setState(() => _ribbonPreferences = preferences);
      }
      await aiAssistantState.refresh();
    } catch (_) {
      // 保留上次已确认的可用状态，弱网时入口仍可立即出现。
    }
  }

  void _aiAvailabilityChanged() {
    if (!mounted) return;
    setState(() {
      _ribbonPreferences = aiAssistantState.featureEnabled == false
          ? null
          : AiRibbonPreferences.current;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                if (BuildChannel.beta)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(
                      'Beta 测试版 · 可能存在问题，数据与正式版独立',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer,
                      ),
                    ),
                  ),
                ListenableBuilder(
                  listenable: Api.instance.offline,
                  builder: (context, _) => SyncNotice(
                    pendingCount: Api.instance.offline.pendingCount,
                    needsLogin: Api.instance.offline.needsLogin,
                    hasConflict: Api.instance.offline.problem != null,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SyncStatusScreen(),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    children: const [
                      ListScreen(),
                      WeekScreen(),
                      DdlScreen(),
                      SettingsScreen(),
                    ],
                  ),
                ),
              ],
            ),
            if (_ribbonPreferences case final preferences?)
              AiRibbon(preferences: preferences, onOpen: _openAiPlanner),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 72,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        // 只保留图标(参考 TickTick 底部纯图标)，隐藏文字标签
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        destinations: [
          NavigationDestination(
            icon: _listIcon(context, selected: false),
            selectedIcon: _listIcon(context, selected: true),
            label: '',
          ),
          const NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '',
          ),
          NavigationDestination(
            icon: _ddlIcon(context, selected: false),
            selectedIcon: _ddlIcon(context, selected: true),
            label: '',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: communityState.unread > 0,
              label: Text('${communityState.unread}'),
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: communityState.unread > 0,
              label: Text('${communityState.unread}'),
              child: const Icon(Icons.settings),
            ),
            label: '我的',
          ),
        ],
      ),
    );
  }

  void _openAiPlanner() {
    showAiPlannerSheet(context);
  }

  /// DDL 图标：加粗 "DDL" 字标，与其它图标明显区分。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Api.instance.offline.start();
      Reminders.sync();
      PlanBus.instance.bump();
      unawaited(communityState.refreshMessages());
    }
  }

  Widget _ddlIcon(BuildContext context, {required bool selected}) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      'DDL',
      style: TextStyle(
        fontSize: 14,
        height: 1,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.3,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
    );
  }

  /// 清单图标：列表。
  Widget _listIcon(BuildContext context, {required bool selected}) {
    return Icon(selected ? Icons.checklist : Icons.checklist_outlined);
  }
}
