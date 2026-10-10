// 从 website/privacy.html 生成 App 内置的隐私说明全文。
//
//   cd app && dart run tool/gen_privacy_text.dart
//
// 加 --check 只校验不写盘（不一致就退出码 1）；test/privacy_policy_test.dart 里
// 走的也是同一条渲染路径，所以平时不用手动跑。
import 'dart:io';

import 'privacy_html.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  final appDir = File.fromUri(Platform.script).parent.parent;
  final source = File('${appDir.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}website${Platform.pathSeparator}privacy.html');
  final target =
      File('${appDir.path}${Platform.pathSeparator}lib'
      '${Platform.pathSeparator}privacy_policy_text.dart');
  if (!source.existsSync()) {
    stderr.writeln('找不到 ${source.path}');
    exitCode = 2;
    return;
  }

  final html = source.readAsStringSync();
  final rendered = renderPrivacyPolicyDart(html);
  // git 的 autocrlf 会在检出时把行尾换成 CRLF，比较前统一成 LF。
  final current = target.existsSync()
      ? target.readAsStringSync().replaceAll('\r\n', '\n')
      : '';

  final doc = parsePrivacyPolicy(html);
  final paragraphs =
      doc.intro.length +
      doc.sections.fold<int>(0, (n, s) => n + s.paragraphs.length) +
      doc.outro.length;

  if (current == rendered) {
    stdout.writeln(
      '已是最新：${doc.sections.length} 节 / $paragraphs 段，'
      '指纹 ${privacyFingerprint(html)}',
    );
    return;
  }
  if (check) {
    stderr.writeln('内置隐私说明与 website/privacy.html 不一致，'
        '请运行 dart run tool/gen_privacy_text.dart');
    exitCode = 1;
    return;
  }
  target.writeAsStringSync(rendered);
  stdout.writeln(
    '已写入 ${target.path}：${doc.sections.length} 节 / $paragraphs 段，'
    '指纹 ${privacyFingerprint(html)}',
  );
}
