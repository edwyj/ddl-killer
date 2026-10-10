import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:plan_app/screens/ai_invite_screen.dart';

void main() {
  testWidgets(
    'referral preview explains both rewards are delivered to messages',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AiInviteScreen(
            preview: (_) async => {
              'kind': 'referral',
              'name': '双方邀请周卡',
              'days': 7,
              'dailyLimit': 6,
              'expiresAt': '2026-10-08T00:00:00Z',
            },
            redeem: (_) async {},
            refresh: () async {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'JOIN-example');
      await tester.tap(find.text('查看并兑换'));
      await tester.pumpAndSettle();
      expect(find.textContaining('双方各收到'), findsOneWidget);
      expect(find.textContaining('领取后开始计时'), findsOneWidget);
    },
  );
  setUpAll(() async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
  });
  testWidgets(
    'mobile invite view and long preview remain usable with keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansSC'),
          home: RepaintBoundary(
            key: const ValueKey('invite-page'),
            child: AiInviteScreen(
              preview: (_) async => {
                'name': '体验周卡',
                'dailyLimit': 10,
                'days': 7,
                'expiresAt': '2026-10-07T02:00:00Z',
                'active': [{}],
              },
              redeem: (_) async {},
              refresh: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('invite-page')),
        matchesGoldenFile('goldens/ai-invite-mobile.png'),
      );
      await tester.enterText(find.byType(TextField), 'DDL-example');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看并兑换'));
      await tester.tap(find.text('查看并兑换'));
      await tester.pumpAndSettle();
      expect(find.text('确认兑换'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('preview requires confirmation and failed redeem retains input', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AiInviteScreen(
          preview: (_) async => {
            'name': '体验周卡',
            'dailyLimit': 10,
            'days': 7,
            'expiresAt': '2026-10-07T02:00:00Z',
            'active': [{}],
          },
          redeem: (_) async {
            calls++;
            throw Exception('offline');
          },
          refresh: () async {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'DDL-example');
    await tester.tap(find.text('查看并兑换'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('次数和有效期不会叠加'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('查看并兑换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认兑换'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('联网后重试'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'DDL-example',
    );
  });
  testWidgets(
    'successful redeem followed by refresh failure retries refresh only',
    (tester) async {
      var redeems = 0;
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AiInviteScreen(
            preview: (_) async => {
              'name': '体验周卡',
              'dailyLimit': 10,
              'days': 7,
              'expiresAt': '2026-10-07T02:00:00Z',
            },
            redeem: (_) async {
              redeems++;
            },
            refresh: () async {
              refreshes++;
              throw Exception('network');
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'DDL-example');
      await tester.tap(find.text('查看并兑换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认兑换'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('刷新额度'));
      await tester.pumpAndSettle();
      expect(redeems, 1);
      expect(refreshes, 2);
    },
  );
}
