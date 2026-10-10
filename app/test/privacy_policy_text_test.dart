import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/privacy_policy_text.dart';

import '../tool/privacy_html.dart';

/// App 内置的《隐私说明》是从 website/privacy.html 生成的（注册时要离线也能读全文）。
/// 这里钉两件事：两边没走样；以及那几个必须写明的境外接收方没被谁顺手删掉。
void main() {
  final html = _readPrivacyHtml();
  final doc = parsePrivacyPolicy(html);
  final allText = [
    doc.title,
    ...doc.intro,
    for (final s in doc.sections) ...[s.title, ...s.paragraphs],
    ...doc.outro,
  ].join('\n');

  test('内置副本与 website/privacy.html 完全一致（改了网站要重新生成）', () {
    final generated = _read('lib/privacy_policy_text.dart');
    expect(
      generated.replaceAll('\r\n', '\n'),
      renderPrivacyPolicyDart(html).replaceAll('\r\n', '\n'),
      reason: '跑一下：cd app && dart run tool/gen_privacy_text.dart',
    );
  });

  test('正文结构完整：标题、小节、每节都有正文', () {
    expect(kPrivacyPolicyTitle, doc.title);
    expect(doc.sections.length, greaterThanOrEqualTo(5));
    for (final section in doc.sections) {
      expect(section.title.trim(), isNotEmpty);
      expect(section.paragraphs, isNotEmpty);
      for (final p in section.paragraphs) {
        expect(p.trim(), isNotEmpty);
      }
    }
  });

  test('境外存储与接收方写在正文里（第 39 条要告知的那几项）', () {
    // 这些是"告知境外接收方"的实质内容，不能被改版顺手抹掉。
    for (final required in ['境外', '甲骨文云', 'Cloudflare', '腾讯云邮件推送']) {
      expect(allText, contains(required), reason: '隐私说明里少了「$required」');
    }
  });

  test('站点结构变了要炸，而不是安静地生成一份空条款', () {
    expect(
      () => parsePrivacyPolicy('<html><body><p>没有 main 也没有 h1</p></body></html>'),
      throwsA(isA<FormatException>()),
    );
  });
}

String _read(String relativeToApp) {
  final file = File(relativeToApp);
  if (!file.existsSync()) {
    fail('找不到 $relativeToApp（flutter test 需要在 app/ 目录下运行）');
  }
  return file.readAsStringSync();
}

String _readPrivacyHtml() {
  for (final path in ['../website/privacy.html', 'website/privacy.html']) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('找不到 website/privacy.html');
}
