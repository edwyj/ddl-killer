import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/build_channel.dart';
import 'package:plan_app/screens/login_screen.dart';

void main() {
  testWidgets(
    'login Android download opens the channel download page, not APK',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      String? opened;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            opened = (call.arguments as Map)['url'] as String;
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        const MaterialApp(home: LoginScreen(debugWebLayout: true)),
      );
      await tester.pumpAndSettle();
      final download = find.text(
        BuildChannel.beta ? '下载 Android 测试版' : '下载 Android 版',
      );
      await tester.ensureVisible(download);
      await tester.pumpAndSettle();
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(
        opened,
        BuildChannel.beta
            ? 'https://beta.ddlkiller.com/download/'
            : 'https://ddlkiller.com/download.html',
      );
      expect(opened, isNot(endsWith('.apk')));
    },
  );
}
