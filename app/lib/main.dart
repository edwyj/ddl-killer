import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'dart:convert';

import 'offline_platform.dart' as offline_platform;

import 'api.dart';
import 'auth_store.dart';
import 'theme.dart';
import 'reminders.dart';
import 'screens/login_screen.dart';
import 'screens/root_screen.dart';
import 'screens/mcp_oauth_consent_screen.dart';
import 'widgets/update_prompt_host.dart';
import 'widgets/permission_intro_host.dart';
import 'ai_assistant_state.dart';
import 'community_state.dart';
import 'ai_ribbon_preferences.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();
bool _endingSession = false;
Future<void> endLocalSession() async {
  if (Api.instance.offline.uid != null) {
    Api.instance.offline.pauseForLogin();
    return;
  }
  if (_endingSession) return;
  _endingSession = true;
  Api.instance.token = null;
  aiAssistantState.clear();
  communityState.clear();
  try {
    await Api.instance.network.clearCache();
    await Reminders.disable();
    await AuthStore.clear();
  } finally {
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    _endingSession = false;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
  String? token;
  try {
    await offline_platform.prepare();
    await Api.instance.offline.initialize();
    token = await AuthStore.loadToken(cachedUid: Api.instance.offline.uid);
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('暂时无法打开本机数据或登录状态：$error'),
                FilledButton(onPressed: main, child: const Text('重试')),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }
  Api.instance.token = token;
  if (Api.instance.offline.uid == null && token != null) {
    final uid = kIsWeb
        ? int.parse(token.substring(4))
        : (jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(token.split('.')[1])),
                ),
              ) as Map)['uid']
              as int;
    await Api.instance.offline.attach(uid, '');
  }
  if (token == null && Api.instance.offline.uid != null) {
    Api.instance.offline.pauseForLogin();
  }
  await Future.wait([
    AiRibbonPreferences.shared(),
    aiAssistantState.preload(Api.instance.offline.uid),
    communityState.attach(
      Api.instance.offline.uid,
      persistent: Api.instance.offline.persistent,
    ),
  ]);
  Api.instance.onSessionChanged = (oldToken, newToken) {
    communityState.clear();
    Reminders.disable(oldToken);
    if (newToken != null) Reminders.sync();
  };
  Api.instance.onUnauthorized = () {
    endLocalSession();
  };
  offline_platform.watch(Api.instance.offline.start);
  Api.instance.offline.addListener(
    () => offline_platform.setPending(Api.instance.offline.pendingCount),
  );
  runApp(const PlanApp());
}

class PlanApp extends StatelessWidget {
  const PlanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) {
        return ValueListenableBuilder<AppColorTheme>(
          valueListenable: ThemeController.palette,
          builder: (context, palette, _) => MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'DDL Killer',
            debugShowCheckedModeBanner: false,
            themeMode: mode,
            theme: buildLightTheme(palette),
            darkTheme: buildDarkTheme(palette),
            builder: (context, child) => PermissionIntroHost(
              navigatorKey: appNavigatorKey,
              child: UpdatePromptHost(
                navigatorKey: appNavigatorKey,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            home: kIsWeb && Uri.base.path == '/oauth/authorize'
                ? OAuthEntryScreen(uri: Uri.base)
                : Api.instance.token == null && !Api.instance.offline.ready
                ? const LoginScreen()
                : const RootScreen(),
          ),
        );
      },
    );
  }
}

class OAuthEntryScreen extends StatefulWidget {
  final Uri uri;
  const OAuthEntryScreen({super.key, required this.uri});
  @override
  State<OAuthEntryScreen> createState() => _OAuthEntryScreenState();
}

class _OAuthEntryScreenState extends State<OAuthEntryScreen> {
  String? requestId;
  String? error;
  @override
  void initState() {
    super.initState();
    Api.instance
        .beginOauth(widget.uri)
        .then((id) {
          if (mounted) setState(() => requestId = id);
        })
        .catchError((e) {
          if (mounted) setState(() => error = '$e');
        });
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return Scaffold(body: Center(child: Text(error!)));
    if (requestId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (Api.instance.token == null) {
      return LoginScreen(onLoggedIn: () => setState(() {}));
    }
    return McpOAuthConsentScreen(requestId: requestId!);
  }
}
