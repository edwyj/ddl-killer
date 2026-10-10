import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/login_screen.dart';
import 'package:plan_app/widgets/secret_text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reveal toggle preserves text and cursor selection', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Password-123')
      ..selection = const TextSelection.collapsed(offset: 5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecretTextField(controller: controller, labelText: '密码'),
        ),
      ),
    );

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).obscureText,
      isTrue,
    );
    await tester.tap(find.bySemanticsLabel('显示密码'));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).obscureText,
      isFalse,
    );
    expect(controller.text, 'Password-123');
    expect(controller.selection.baseOffset, 5);
    expect(find.bySemanticsLabel('隐藏密码'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('隐藏密码'));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).obscureText,
      isTrue,
    );
  });

  testWidgets('login and confirmation password toggles are independent', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();
    expect(find.bySemanticsLabel('显示密码'), findsOneWidget);

    await tester.ensureVisible(find.text('创建一个账号'));
    await tester.tap(find.text('创建一个账号'));
    await tester.ensureVisible(find.bySemanticsLabel('显示密码').first);
    await tester.pump();
    expect(find.bySemanticsLabel('显示密码'), findsNWidgets(2));

    await tester.tap(find.bySemanticsLabel('显示密码').first);
    await tester.pump();
    final fields = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .toList();
    expect(fields[1].obscureText, isFalse);
    expect(fields[2].obscureText, isTrue);
  });

  testWidgets('API key uses key-specific reveal semantics', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecretTextField(
            controller: TextEditingController(text: 'sk-secret'),
            labelText: 'API Key',
            secretKind: SecretKind.apiKey,
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('显示 Key'), findsOneWidget);
    expect(find.bySemanticsLabel('显示密码'), findsNothing);
  });
}
