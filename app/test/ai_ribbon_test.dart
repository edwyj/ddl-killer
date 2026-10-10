import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/ai_ribbon_preferences.dart';
import 'package:plan_app/widgets/ai_ribbon.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AiRibbonPreferences> prefs([
  Map<String, Object> values = const {},
]) async {
  SharedPreferences.setMockInitialValues(values);
  return AiRibbonPreferences.load();
}

Widget host(AiRibbonPreferences preferences, VoidCallback onOpen) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 500,
          child: Stack(
            children: [
              const ColoredBox(color: Colors.white),
              AiRibbon(
                preferences: preferences,
                onOpen: onOpen,
                bottomInset: 80,
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  testWidgets('visible by default and tap opens exactly once', (tester) async {
    final semantics = tester.ensureSemantics();
    final preferences = await prefs();
    var opens = 0;
    await tester.pumpWidget(host(preferences, () => opens++));
    expect(find.text('🎀'), findsOneWidget);
    expect(find.bySemanticsLabel('打开 AI 计划助手'), findsOneWidget);
    await tester.tap(find.text('🎀'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    semantics.dispose();
  });

  testWidgets('light surface stays pale and supports the selected emoji', (
    tester,
  ) async {
    final preferences = await prefs();
    await tester.pumpWidget(host(preferences, () {}));
    final surface = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('ai-ribbon-surface')),
    );
    final decoration = surface.decoration as BoxDecoration;
    expect(
      decoration.gradient!.colors.every((c) => c.computeLuminance() > 0.7),
      true,
    );
    expect(decoration.border, isNull);
    await preferences.setEmoji('⭐');
    await tester.pumpAndSettle();
    expect(find.text('⭐'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag over eight pixels never opens and snaps to nearest side', (
    tester,
  ) async {
    final preferences = await prefs();
    var opens = 0;
    await tester.pumpWidget(host(preferences, () => opens++));
    await tester.drag(find.text('🎀'), const Offset(-220, 40));
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(preferences.side, AiRibbonSide.left);
    expect(tester.getTopLeft(find.byType(AiRibbonHandle)).dx, closeTo(8, 1));
  });

  testWidgets('vertical drag clamps above bottom navigation', (tester) async {
    final preferences = await prefs();
    await tester.pumpWidget(host(preferences, () {}));
    await tester.drag(find.text('🎀'), const Offset(0, 1000));
    await tester.pumpAndSettle();
    final bottom = tester.getBottomRight(find.byType(AiRibbonHandle)).dy;
    expect(bottom, lessThanOrEqualTo(420.1));
    expect(preferences.yFraction, 1);
  });

  testWidgets('disabled preference hides the ribbon', (tester) async {
    final preferences = await prefs({'ai_ribbon_enabled_v1': false});
    await tester.pumpWidget(host(preferences, () {}));
    expect(find.text('🎀'), findsNothing);
  });

  testWidgets('saved position restores and invalid multi-grapheme falls back', (
    tester,
  ) async {
    final preferences = await prefs({
      'ai_ribbon_side_v1': 'left',
      'ai_ribbon_y_v1': 0.25,
      'ai_ribbon_emoji_v1': '🎀✨',
    });
    await tester.pumpWidget(host(preferences, () {}));
    expect(preferences.side, AiRibbonSide.left);
    expect(preferences.yFraction, 0.25);
    expect(preferences.emoji, '🎀');
    expect(tester.getTopLeft(find.byType(AiRibbonHandle)).dx, closeTo(8, 1));
  });

  test('single emoji grapheme persists; ordinary text does not', () async {
    final preferences = await prefs();
    expect(await preferences.setEmoji('🧑‍💻'), true);
    expect(preferences.emoji, '🧑‍💻');
    expect(await preferences.setEmoji('A'), false);
    expect(await preferences.setEmoji('🎀✨'), false);
  });
}
