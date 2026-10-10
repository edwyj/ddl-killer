import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/screens/ddl_screen.dart';

/// DDL 页两个显示 bug 的回归测试。
///
/// 页面一进来就拉 /api/inbox，拉不到就整页停在错误态、日历根本不渲染，
/// 所以先把 HTTP 顶掉回一个空清单。日历网格本身是纯本地算的（节日走 lunar 包），
/// 不碰网络，正好能单独验。
///
/// 替换口是 http 包官方的 runWithClient：Client() 工厂会去读 zone 里的工厂，
/// 测试环境默认那套"所有请求都 400"的拦截因此可以被绕过。
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  Future<void> pumpDdl(WidgetTester tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: DdlScreen()));
      await tester.pumpAndSettle();
    }, () => MockClient((_) async => http.Response('[]', 200)));
  }

  testWidgets('切换按钮的提示语跟着当前视图走', (tester) async {
    await pumpDdl(tester);

    // 初始是月视图 → 该提示"切到周视图"
    expect(find.byTooltip('切到周视图'), findsOneWidget);

    await tester.tap(find.byTooltip('切到周视图'));
    await tester.pumpAndSettle();

    // 切到周视图之后必须改口。
    // 旧实现里顶栏在 AnimatedBuilder 外面、_toggleZoom 又不 setState，
    // 于是两种视图下都停在"切到周视图" —— 这两条断言就是钉这个。
    expect(find.byTooltip('切到月视图'), findsOneWidget);
    expect(find.byTooltip('切到周视图'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('节日文字整块放得进槽位，不会被裁掉', (tester) async {
    await pumpDdl(tester);

    final slots = tester.renderObjectList<RenderBox>(find.byType(FittedBox));
    expect(slots, isNotEmpty, reason: '当前月至少有一天带节日/节气，否则这条测了个寂寞');

    // 槽位只有 13px 高。旧实现把 Text 直接塞进去，长名字（「全国中小学生安全教育日」
    // 这种）换到第二行就是 19px，下半截被 SizedBox 裁掉 —— 正是看到的"显示不全"。
    // 现在整块缩放进槽位，那就没有任何一个节日盒子该超出 13px。
    for (final b in slots) {
      expect(
        b.size.height,
        lessThanOrEqualTo(13.0),
        reason: '节日槽位 ${b.size} 高过 13px，说明又被裁了',
      );
    }

    // 这条是月视图（没缩放），上面那个既有溢出不该出现 —— 所以这里仍然是严格判空。
    expect(tester.takeException(), isNull);
  });
}
