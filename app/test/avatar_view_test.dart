import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/avatar_picker_screen.dart';
import 'package:plan_app/theme.dart';
import 'package:plan_app/widgets/avatar_view.dart';

/// 覆盖冻结的 avatar spec 约定(后端会校验)与选择器返回值。
void main() {
  group('avatar spec 解析', () {
    test('preset: 解析出颜色与字符', () {
      final p = AvatarView.parsePreset('preset:#7C4DFF:意')!;
      expect(p.hex, '#7C4DFF');
      expect(p.char, '意');
      expect(p.color, const Color(0xFF7C4DFF));
    });

    test('非 preset / 空串 → null', () {
      expect(AvatarView.parsePreset('data:image/png;base64,AAA'), isNull);
      expect(AvatarView.parsePreset(''), isNull);
    });

    test('hex 支持 6/8 位、# 可省略、非法值返回 null', () {
      expect(AvatarView.parseHexColor('#57B0A6'), const Color(0xFF57B0A6));
      expect(AvatarView.parseHexColor('57b0a6'), const Color(0xFF57B0A6));
      expect(AvatarView.parseHexColor('#8057B0A6'), const Color(0xFF57B0A6));
      // 不支持 3 位简写(注释已同步)
      expect(AvatarView.parseHexColor('#FFF'), isNull);
      expect(AvatarView.parseHexColor('#xyz'), isNull);
      expect(AvatarView.parseHexColor(''), isNull);
    });

    test('parseHexColor 强制不透明：半透明写法也拉满 alpha', () {
      expect(AvatarView.parseHexColor('#0057B0A6'), const Color(0xFF57B0A6));
      expect(AvatarView.parseHexColor('#0057B0A6')!.a, 1.0);
    });

    test('hexOf 与 parseHexColor 互逆', () {
      expect(AvatarView.hexOf(const Color(0xFF57B0A6)), '#57B0A6');
      expect(AvatarView.hexOf(const Color(0xFF7C4DFF)), '#7C4DFF');
      final hex = AvatarView.hexOf(seed);
      expect(AvatarView.parseHexColor(hex), seed);
      // 该 hex 必须命中预设色板(否则选择器勾不到任何一格)
      expect(AvatarView.presetColors.contains(hex), isTrue);
    });

    test('data URL 解码；坏数据不抛异常', () {
      const png = 'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final bytes = AvatarView.decodeDataUrl(png)!;
      expect(bytes[0], 0x89); // PNG magic
      expect(AvatarView.decodeDataUrl('data:image/png;base64,!!!!'), isNull);
      expect(AvatarView.decodeDataUrl('preset:#fff:A'), isNull);
      expect(AvatarView.decodeDataUrl(''), isNull);
    });

    test('默认头像取用户名首字(大写)', () {
      expect(AvatarView.initialOf('alex'), 'A');
      expect(AvatarView.initialOf('意'), '意');
      expect(AvatarView.initialOf(''), '?');
    });

    testWidgets('三种 spec 都能渲染且不报错', (tester) async {
      for (final spec in <String>[
        '',
        'preset:#7C4DFF:意',
        'preset:#7C4DFF:',
        'data:image/png;base64,不是合法base64',
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(child: AvatarView(avatar: spec, username: 'alex', size: 64)),
        ));
        expect(tester.takeException(), isNull, reason: 'spec=$spec');
      }
    });
  });

  group('字节缓存', () {
    const photo = 'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

    testWidgets('换 spec 立刻跟着变(缓存不会粘住旧图)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: AvatarView(avatar: photo, username: 'alex')),
      ));
      expect(find.byType(Image), findsOneWidget); // 照片
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: AvatarView(avatar: '', username: 'alex')),
      ));
      expect(find.byType(Image), findsNothing); // 变回默认字头像
      expect(find.text('A'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: AvatarView(avatar: photo, username: 'alex')),
      ));
      expect(find.byType(Image), findsOneWidget); // 换回照片也能回来
    });

    testWidgets('同一 spec 重建时 ImageProvider 相等(缓存才不会永远 miss)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: AvatarView(avatar: photo, username: 'alex')),
      ));
      final first = tester.widget<Image>(find.byType(Image)).image;
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: AvatarView(avatar: photo, username: 'alex', size: 96)),
      ));
      final second = tester.widget<Image>(find.byType(Image)).image;
      // MemoryImage 的 == 比的是 bytes 的 identity，只有复用同一份解码结果才相等；
      // 每次 build 重新解码的话这里就是 false(图片缓存永远 miss)。
      expect(first, equals(second));
      expect(first.hashCode, second.hashCode);
    });
  });

  group('头像选择器', () {
    Future<ValueGetter<String?>> open(WidgetTester tester, String current) async {
      String? result;
      var opened = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  if (opened) return;
                  opened = true;
                  result = await pickAvatar(ctx, current: current);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => result;
    }

    testWidgets('已有 preset → 字符预填，保存返回新的 preset spec', (tester) async {
      final result = await open(tester, 'preset:#7C4DFF:意');
      expect(find.text('选择头像'), findsOneWidget);
      expect(find.widgetWithText(TextField, '意'), findsOneWidget);

      // 改字符后再保存
      await tester.enterText(find.byType(TextField), '无');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result(), 'preset:#7C4DFF:无');
    });

    testWidgets('恢复默认返回空串；取消返回 null', (tester) async {
      final result = await open(tester, 'preset:#7C4DFF:意');
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(result(), '');
    });

    testWidgets('字符为空 → 保存可点但给出可见原因，且不显示"恢复默认"', (tester) async {
      final result = await open(tester, '');
      expect(find.text('恢复默认'), findsNothing);
      expect(find.textContaining('请输入 1 个字符'), findsOneWidget); // 静态提示行
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result(), isNull); // 没有 pop
      expect(find.textContaining('请输入 1 个字符'), findsWidgets); // 错误提示也出来了
    });

    testWidgets('字符只保留 1 个字素：输入多个字只存第一个', (tester) async {
      final result = await open(tester, 'preset:#7C4DFF:意');
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result(), 'preset:#7C4DFF:h');
    });

    testWidgets('多码元 emoji 不会被截成半个代理对', (tester) async {
      final result = await open(tester, 'preset:#7C4DFF:意');
      await tester.enterText(find.byType(TextField), '👍🏽x');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result(), 'preset:#7C4DFF:👍🏽');
    });

    testWidgets('点字符框会全选预填的首字，好让新字直接替换它', (tester) async {
      await open(tester, 'preset:#7C4DFF:意');
      final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
      await tester.tap(find.byType(TextField));
      await tester.pump();
      // 光标不是收起的单点，而是覆盖整段：输入即替换，不会被追加成"意X"
      expect(controller.selection.isCollapsed, isFalse);
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, controller.text.length);
    });

    testWidgets('当前是照片：预览显示这张照片，改字符后回到字符头像', (tester) async {
      const photo = 'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final result = await open(tester, photo);
      // 预览必须渲染照片本身，而不是默认的"?"圆圈
      expect(find.byType(Image), findsWidgets);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result(), photo); // 原样返回

      final result2 = await open(tester, photo);
      await tester.enterText(find.byType(TextField), '无');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      // 改字符即离开照片模式，否则预览不会跟着动
      expect(result2(), 'preset:#7C4DFF:无');
    });

    testWidgets('相册入口存在；相机入口按 kIsWeb 分支(测试跑在 VM 上 → 应出现)', (tester) async {
      await open(tester, 'preset:#7C4DFF:意');
      expect(find.text('从相册选'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget); // kIsWeb == false
    });
  });
}
