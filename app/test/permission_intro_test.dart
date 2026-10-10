import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/widgets/permission_intro_host.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> show(
    WidgetTester tester,
    Future<bool> Function() request,
  ) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        builder: (_, child) => PermissionIntroHost(
          navigatorKey: key,
          requestNotifications: request,
          child: child!,
        ),
        home: const Scaffold(body: Text('登录')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first launch explains permissions; skipping never requests and never repeats',
    (tester) async {
      var calls = 0;
      await show(tester, () async {
        calls++;
        return true;
      });
      expect(find.text('先说清楚权限'), findsOneWidget);
      expect(calls, 0);
      await tester.tap(find.text('暂不开启'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await show(tester, () async {
        calls++;
        return true;
      });
      expect(find.text('先说清楚权限'), findsNothing);
      expect(calls, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'only explicit allow requests notifications, denial keeps login usable',
    (tester) async {
      var calls = 0;
      await show(tester, () async {
        calls++;
        return false;
      });
      await tester.tap(find.text('允许通知'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('登录'), findsOneWidget);
      expect(find.text('先说清楚权限'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
