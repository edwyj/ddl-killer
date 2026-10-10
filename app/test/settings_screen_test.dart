import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/about_screen.dart';
import 'package:plan_app/app_version.dart';
import 'package:plan_app/screens/settings_screen.dart';
import 'package:plan_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的」页的界面行为测试。
///
/// 说明：TestWidgetsFlutterBinding 会把所有 HTTP 请求拦成 400（真实网络在
/// 组件测试里跑不通），所以这里顺便把“接口不可用”当成本套件的一部分：
/// 页面必须不崩、不显示假统计、给出提示，写操作失败必须留在原页并报错。
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeController.mode.value = ThemeMode.light;
    ThemeController.palette.value = AppColorTheme.teal;
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
  }

  /// ListView 懒加载：下面的分组要滚动到可见才会被构建。
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('接口不可用：页面不崩、不显示垃圾统计、给出提示', (tester) async {
    await pumpSettings(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('资料加载失败，下拉可重试'), findsOneWidget);
    // 统计拉不到就整块隐藏，绝不显示 0/假数字
    expect(find.textContaining('清单 '), findsNothing);
    expect(find.textContaining('课程 '), findsNothing);
    // 各组与入口都还在，页面可正常使用
    expect(find.text('账号与安全'), findsOneWidget);
    expect(find.text('修改昵称'), findsOneWidget);
    expect(find.text('修改密码'), findsOneWidget);
    await scrollTo(tester, find.text('计划与工具'));
    expect(find.text('计划与工具'), findsOneWidget);
    expect(find.text('导入课表'), findsOneWidget);
    expect(find.text('未导入'), findsOneWidget); // has_schedule 拉不到 → 未导入

    final appearanceTile = find.widgetWithText(ListTile, '外观');
    await scrollTo(tester, appearanceTile);
    expect(appearanceTile, findsOneWidget);

    await scrollTo(tester, find.text('退出登录'));
    expect(find.text('关于 DDL Killer'), findsOneWidget);
    expect(find.text('版本 ${AboutScreen.version}'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('点头部打开头像选择器；取消不改变任何东西', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('profile-header')));
    await tester.pumpAndSettle();
    expect(find.text('选择头像'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('选择头像'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外观入口显示当前模式和主题色并打开独立页面', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, find.text('同步与离线数据'));
    expect(find.text('同步与离线数据'), findsOneWidget);
    final appearanceTile = find.widgetWithText(ListTile, '外观');
    await scrollTo(tester, appearanceTile);
    expect(find.text('浅色 · 湖蓝'), findsOneWidget);
    await tester.ensureVisible(appearanceTile);
    await tester.pumpAndSettle();
    await tester.tap(appearanceTile);
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('湖蓝'), findsOneWidget);
  });

  testWidgets('修改昵称：接口失败时留在原页并报错，不静默丢改动', (tester) async {
    await pumpSettings(tester);
    await scrollTo(tester, find.text('修改昵称'));
    await tester.tap(find.text('修改昵称'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '无意');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget); // 没有 pop，改动还在输入框里
    expect(find.textContaining('400'), findsOneWidget); // 显示了后端错误
  });

  testWidgets('关于页展示应用信息与本次更新日志', (tester) async {
    await pumpSettings(tester);

    await scrollTo(tester, find.text('关于 DDL Killer'));
    await tester.tap(find.text('关于 DDL Killer'));
    await tester.pumpAndSettle();

    expect(find.text('DDL Killer'), findsOneWidget);
    expect(find.bySemanticsLabel('DDL Killer Logo'), findsOneWidget);
    expect(find.text('版本 ${AboutScreen.version}'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('下载安卓版 APK'), findsNothing);
    await scrollTo(tester, find.text('最新版本变化'));
    expect(find.textContaining('「我的」页全新改版'), findsNothing);
    expect(find.text(AppVersion.notes), findsOneWidget);
    // 入口位于下方；窄屏时滚动到可见区域再核对。
    expect(find.text('下载安卓版 APK'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
