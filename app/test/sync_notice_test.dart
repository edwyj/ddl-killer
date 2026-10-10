import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/widgets/sync_notice.dart';

void main() {
  Widget page(
    int count,
    VoidCallback tap, {
    bool login = false,
    bool conflict = false,
  }) => MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.only(top: 32),
      ),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              SyncNotice(
                pendingCount: count,
                needsLogin: login,
                hasConflict: conflict,
                onTap: tap,
              ),
              Expanded(
                child: Scaffold(appBar: AppBar(title: const Text('任务'))),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  testWidgets('synced state takes no space even with expired login', (
    tester,
  ) async {
    await tester.pumpWidget(page(0, () {}, login: true));
    expect(find.byType(InkWell), findsNothing);
    expect(tester.getSize(find.byType(SyncNotice)).height, 0);
    expect(tester.getTopLeft(find.byType(AppBar)).dy, 32);
  });
  testWidgets(
    'Android status inset is consumed once; pending notice stays compact and opens details',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(page(3, () => taps++));
      final height = tester.getSize(find.byType(SyncNotice)).height;
      expect(height, inInclusiveRange(36, 40));
      expect(tester.getTopLeft(find.byType(AppBar)).dy, 32 + height);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
      await tester.tap(find.text('3 项修改待同步'));
      expect(taps, 1);
    },
  );
  testWidgets('pending conflict shows actionable short text', (tester) async {
    await tester.pumpWidget(page(2, () {}, conflict: true));
    expect(find.text('2 项修改待同步 · 需要处理冲突'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
