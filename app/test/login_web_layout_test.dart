@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plan_app/screens/login_screen.dart';

void main() {
  for (final width in [390.0, 1920.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'web login fits $width $brightness and retains password toggle',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: const LoginScreen(),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('欢迎回来'), findsOneWidget);
          expect(find.text('继续安排今天。'), findsOneWidget);
          expect(find.byType(Scrollbar), findsNothing);
          expect(find.text('你的每日时间轴'), findsNothing);
          final field = find.byType(TextField).first;
          final rect = tester.getRect(field);
          expect(rect.width, lessThanOrEqualTo(444));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
          await tester.enterText(
            find.byType(TextField).at(1),
            'Example-password',
          );
          await tester.tap(find.byTooltip('显示密码'));
          await tester.pump();
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText).at(1))
                .obscureText,
            false,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
