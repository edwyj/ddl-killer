import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/screens/about_screen.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/app_updates.dart';
import 'package:plan_app/app_version.dart';
import 'package:plan_app/build_channel.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Beta Web and native detect newer releases; asset-only updates apply to Web', () async {
    final oldRevision = List.filled(64, 'a').join();
    final newRevision = List.filled(64, 'b').join();
    Future<AppUpdates> check(bool web, int installedBuild) async {
      final updates = AppUpdates(
        web: web,
        installedWebRevision: oldRevision,
        installed: () async => (name: '0.11.5-beta.2', build: installedBuild),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'version': '0.11.5-beta.2',
                'build_number': 31,
                'apk_url': 'https://beta.ddlkiller.com/',
                'web_revision': newRevision,
                'notes': '测试版更新',
              }),
            ),
            200,
          ),
        ),
      );
      await updates.check(force: true);
      return updates;
    }

    final olderWeb = await check(true, 30);
    expect(olderWeb.available, true);
    olderWeb.dispose();
    final sameBuildWeb = await check(true, 31);
    expect(sameBuildWeb.available, true);
    sameBuildWeb.dispose();
    final native = await check(false, 30);
    expect(native.available, true);
    expect(native.status, '发现新版本 0.11.5-beta.2');
    expect(
      native.release!.downloadUrl.toString(),
      'https://beta.ddlkiller.com/download/',
    );
    native.dispose();
    final sameNative = await check(false, 31);
    expect(sameNative.available, false);
    expect(sameNative.status, '已经是最新测试版');
    sameNative.dispose();
  }, skip: !BuildChannel.beta);
  test(
    'Beta uses its fixed API origin and never accepts a stable update manifest',
    () {
      expect(Api.base, 'https://beta.ddlkiller.com');
      expect(AppVersion.displayName, BuildChannel.version);
      expect(
        AppRelease.parse({
          'version': '0.11.5-beta.1',
          'build_number': 30,
          'apk_url': 'https://beta.ddlkiller.com/',
          'notes': '测试版',
        }).version,
        '0.11.5-beta.1',
      );
      expect(
        () => AppRelease.parse({
          'version': '0.11.5',
          'build_number': 31,
          'apk_url': 'https://ddlkiller.com/releases/ddl-killer-0.11.5-31.apk',
        }),
        throwsFormatException,
      );
    },
    skip: !BuildChannel.beta,
  );
  testWidgets(
    'older Beta APK shows an update action when newer release notes are visible',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final updates = AppUpdates(
        web: false,
        installed: () async => (name: '0.11.6-beta.1', build: 36),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'version': '0.12.0-beta.2',
                'build_number': 40,
                'apk_url': 'https://beta.ddlkiller.com/',
                'notes': '修复测试版更新检查',
              }),
            ),
            200,
          ),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: AboutScreen(updates: updates)));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 0.12.0-beta.2'), findsOneWidget);
      expect(find.text('更新到 0.12.0-beta.2'), findsOneWidget);
      expect(find.text('0.12.0-beta.2'), findsOneWidget);
      expect(find.text('当前为测试版，安装包可从 Beta 网页下载'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
    },
    skip: !BuildChannel.beta,
  );
  test(
    'Beta native can prompt and snooze without accepting stable manifests',
    () async {
      SharedPreferences.setMockInitialValues({});
      final updates = AppUpdates(
        web: false,
        installed: () async => (name: '0.12.0-beta.1', build: 39),
        client: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'version': '0.12.0-beta.2',
                'build_number': 40,
                'apk_url': 'https://beta.ddlkiller.com/',
                'notes': '修复更新检查',
              }),
            ),
            200,
          ),
        ),
      );
      await updates.check(force: true);
      expect(updates.available, true);
      expect(await updates.shouldPrompt(), true);
      await updates.defer(40);
      expect(await updates.shouldPrompt(), false);
      updates.dispose();
    },
    skip: !BuildChannel.beta,
  );
}
