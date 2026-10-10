import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/app_updates.dart';
import 'package:plan_app/widgets/update_prompt_host.dart';
import 'package:plan_app/screens/login_screen.dart';

Map<String, dynamic> manifest(int build) => {
  'version': '0.6.0',
  'build_number': build,
  'apk_url': 'https://ddlkiller.com/releases/ddl-killer-0.6.0-$build.apk',
  'notes': '更新测试',
};
http.Response responseFor(int build) => http.Response.bytes(
  utf8.encode(jsonEncode(manifest(build))),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
void main() {
  test(
    'Web detects changed assets even when the release build stays the same',
    () async {
      final oldRevision = List.filled(64, 'a').join();
      final newRevision = List.filled(64, 'b').join();
      var current = newRevision;
      final updates = AppUpdates(
        web: true,
        installedWebRevision: oldRevision,
        installed: () async => (name: '0.6.0', build: 10),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode({...manifest(10), 'web_revision': current})),
            200,
          ),
        ),
      );
      await updates.check(force: true);
      expect(updates.available, true);
      current = oldRevision;
      await updates.check(force: true);
      expect(updates.available, false);
      updates.dispose();
    },
  );
  test(
    'web manifest uses configured same origin without credentials',
    () async {
      final updates = AppUpdates(
        manifestOrigin: Uri.parse('https://app.ddlkiller.com/old-path?q=old'),
        client: MockClient((request) async {
          expect(request.url.host, 'app.ddlkiller.com');
          expect(request.url.path, '/app-update.json');
          expect(request.url.queryParameters.containsKey('q'), false);
          expect(request.headers.containsKey('authorization'), false);
          return responseFor(99);
        }),
      );
      await updates.check();
      expect(updates.available, true);
      updates.dispose();
    },
  );
  test('native alternate endpoint recovers connection failure', () async {
    final hosts = <String>[];
    final updates = AppUpdates(
      client: MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'ddlkiller.com') {
          throw http.ClientException('private network detail');
        }
        return responseFor(99);
      }),
    );
    await updates.check();
    expect(hosts, ['ddlkiller.com', 'app.ddlkiller.com']);
    expect(updates.error, isNull);
    expect(updates.available, true);
    expect(updates.diagnostic.contains('private network detail'), false);
    updates.dispose();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('uses build number, bypasses cached manifests and avoids false latest on failures', () async {
    var code = 9, fail = false, calls = 0;
    final updates = AppUpdates(
      installed: () async => (name: '0.6.0', build: 9),
      client: MockClient((r) async {
        calls++;
        expect(r.url.path, '/app-update.json');
        expect(r.url.queryParameters.containsKey('t'), true);
        expect(r.headers.containsKey('authorization'), false);
        return fail ? http.Response('error', 503) : responseFor(code);
      }),
    );
    await updates.check();
    expect(updates.available, false);
    expect(updates.status, '已经是最新版本', reason: '${updates.lastError}');
    code = 10;
    await updates.check(force: true);
    expect(updates.available, true);
    code = 8;
    await updates.check(force: true);
    expect(updates.available, false);
    fail = true;
    await updates.check(force: true);
    expect(updates.status, '暂时无法检查更新');
    await updates.check();
    expect(calls, 5);
    updates.dispose();
  });
  test(
    'deferral persists for one day and applies only to that release',
    () async {
      var now = DateTime(2026, 9, 15), build = 10;
      AppUpdates make() => AppUpdates(
        now: () => now,
        installed: () async => (name: '0.6.0', build: 9),
        client: MockClient((_) async => responseFor(build)),
      );
      var updates = make();
      await updates.check();
      expect(
        await updates.shouldPrompt(),
        true,
        reason: '${updates.lastError}',
      );
      await updates.defer(10);
      updates.dispose();
      updates = make();
      await updates.check();
      expect(await updates.shouldPrompt(), false);
      build = 11;
      await updates.check(force: true);
      expect(await updates.shouldPrompt(), true);
      build = 10;
      now = now.add(const Duration(days: 1));
      await updates.check(force: true);
      expect(await updates.shouldPrompt(), true);
      updates.dispose();
    },
  );
  test('rejects untrusted URLs and mismatched release artifacts', () {
    for (final url in [
      'http://ddlkiller.com/releases/ddl-killer-0.6.0-10.apk',
      'https://evil.example/a.apk',
      'https://ddlkiller.com/releases/ddl-killer-0.6.0-9.apk',
    ]) {
      expect(
        () => AppRelease.parse({...manifest(10), 'apk_url': url}),
        throwsFormatException,
      );
    }
  });
  testWidgets('login screen uses the product logo instead of a calendar icon', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    expect(find.bySemanticsLabel('DDL Killer Logo'), findsOneWidget);
    expect(find.byIcon(Icons.event_note), findsNothing);
  });
  testWidgets(
    'Android prompt is optional and later choice preserves current screen',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final updates = AppUpdates(
        installed: () async => (name: '0.6.0', build: 9),
        client: MockClient((_) async => responseFor(10)),
      );
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          builder: (c, child) => UpdatePromptHost(
            navigatorKey: nav,
            updates: updates,
            child: child!,
          ),
          home: const Scaffold(body: Text('我的任务')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 0.6.0'), findsOneWidget);
      expect(find.text('立即更新'), findsOneWidget);
      await tester.tap(find.text('暂不更新'));
      await tester.pumpAndSettle();
      expect(find.text('我的任务'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(await updates.shouldPrompt(), false);
      await tester.pumpWidget(const SizedBox.shrink());
      updates.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  test(
    'Web deferral is scoped to the asset revision as well as the build',
    () async {
      var revision = List.filled(64, 'b').join();
      final updates = AppUpdates(
        web: true,
        installedWebRevision: List.filled(64, 'a').join(),
        installed: () async => (name: '0.6.0', build: 9),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode({...manifest(9), 'web_revision': revision})),
            200,
          ),
        ),
      );
      await updates.check();
      await updates.defer(9);
      expect(await updates.shouldPrompt(), false);
      revision = List.filled(64, 'c').join();
      await updates.check(force: true);
      expect(await updates.shouldPrompt(), true);
      updates.dispose();
    },
  );
  for (final web in [true, false]) {
    testWidgets(
      'automatic prompt tracks later checks on ${web ? 'Web' : 'Android'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var build = 9;
        final updates = AppUpdates(
          web: web,
          installed: () async => (name: '0.6.0', build: 9),
          client: MockClient((_) async => responseFor(build)),
        );
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: nav,
            builder: (_, child) => UpdatePromptHost(
              navigatorKey: nav,
              updates: updates,
              child: child!,
            ),
            home: const Scaffold(body: Text('我的任务')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        build = 10;
        await updates.check(force: true);
        await tester.pumpAndSettle();
        expect(find.text('发现新版本 0.6.0'), findsOneWidget);
        await tester.tap(find.text('暂不更新'));
        await tester.pumpAndSettle();
        await updates.check(force: true);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('我的任务'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        updates.dispose();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  for (final pending in [0, 1]) {
    testWidgets(
      'Web startup prompts but reloads only on consent with $pending pending writes',
      (tester) async {
        var reloads = 0;
        final updates = AppUpdates(
          web: true,
          installed: () async => (name: '0.6.0', build: 9),
          client: MockClient((_) async => responseFor(10)),
        );
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: nav,
            builder: (_, child) => UpdatePromptHost(
              navigatorKey: nav,
              updates: updates,
              reloadWeb: () async {
                reloads++;
              },
              pendingChanges: () => pending,
              child: child!,
            ),
            home: const Scaffold(body: Text('我的任务')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('发现新版本 0.6.0'), findsOneWidget);
        expect(reloads, 0);
        await tester.tap(find.text('更新网页'));
        await tester.pumpAndSettle();
        expect(reloads, pending == 0 ? 1 : 0);
        if (pending > 0) expect(find.text('请先同步本机修改，再更新网页'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        updates.dispose();
      },
    );
  }
  testWidgets('returning after five minutes retries a failed automatic check', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 2), fail = true, calls = 0;
    final updates = AppUpdates(
      web: true,
      now: () => now,
      installed: () async => (name: '0.6.0', build: 9),
      manifestOrigin: Uri.https('app.ddlkiller.com'),
      client: MockClient((_) async {
        calls++;
        return fail ? http.Response('', 503) : responseFor(10);
      }),
    );
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (_, child) => UpdatePromptHost(
          navigatorKey: nav,
          updates: updates,
          child: child!,
        ),
        home: const Scaffold(body: Text('我的任务')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 6));
    fail = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('发现新版本 0.6.0'), findsOneWidget);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    updates.dispose();
  });
}
