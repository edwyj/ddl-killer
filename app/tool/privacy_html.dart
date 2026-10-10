// 隐私说明的唯一事实来源是仓库里的 website/privacy.html（也就是 ddlkiller.com/privacy.html
// 这一份）。注册时的“读完才能同意”需要 App 里有一份不依赖网络的全文，所以从那份 HTML
// 抽出一份内置副本。
//
// 这个库被两边共用：
//   - tool/gen_privacy_text.dart 生成 lib/privacy_policy_text.dart
//   - test/privacy_policy_test.dart 重新抽一遍，和内置副本比对，防止两边走样
//
// 解析器只认我们自己写的这份 HTML（单行、只用 <h1>/<h2>/<p>/<a>），所以不上 HTML 解析库；
// 一旦站点结构变了导致抽不出东西，这里会直接抛错，而不是静默生成一份空条款。

/// 隐私说明里的一节：一个小标题加它下面的若干段。
class PrivacySection {
  final String title;
  final List<String> paragraphs;
  const PrivacySection(this.title, this.paragraphs);
}

/// 解析出来的整篇说明。
class PrivacyDocument {
  /// 页面上的 <h1>，直接拿来当弹窗标题，免得我们自己另起一个名字。
  final String title;

  /// 第一个小标题之前的引言段落。
  final List<String> intro;

  final List<PrivacySection> sections;

  /// 最后一节之后的段落（例如“进入应用管理数据与权限”这类收尾）。
  final List<String> outro;

  const PrivacyDocument({
    required this.title,
    required this.intro,
    required this.sections,
    required this.outro,
  });
}

const _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'hellip': '…',
};

/// 从整页 HTML 里抽出正文。只认 <main> 里的内容，页头和站点导航都不算条款。
PrivacyDocument parsePrivacyPolicy(String html) {
  final main = RegExp(r'<main[^>]*>(.*)</main>', dotAll: true)
      .firstMatch(html)
      ?.group(1);
  if (main == null) {
    throw const FormatException('privacy.html 里找不到 <main>，站点结构变了？');
  }
  // 跳过 <h1> 之前的站点导航链接（“← DDL Killer 官网”是页面外壳，不是说明本身）。
  final h1Start = main.indexOf('<h1');
  if (h1Start < 0) {
    throw const FormatException('privacy.html 的 <main> 里找不到 <h1>');
  }
  final body = main.substring(h1Start);

  final titleMatch = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(body);
  if (titleMatch == null) {
    throw const FormatException('privacy.html 的 <h1> 没有正常闭合');
  }
  final title = _text(titleMatch.group(1)!);
  final rest = body.substring(titleMatch.end);

  // 最后一个 </section> 之后的内容是收尾（例如“进入应用管理数据与权限”），
  // 不属于最后一节，所以分成两段各扫各的。
  final closeTag = '</section>';
  final lastSectionEnd = rest.lastIndexOf(closeTag);
  final bodyPart =
      lastSectionEnd < 0 ? rest : rest.substring(0, lastSectionEnd + closeTag.length);
  final tailPart = lastSectionEnd < 0 ? '' : rest.substring(lastSectionEnd + closeTag.length);

  // 按出现顺序取 <h2> 和 <p>：h2 开新的一节，p 归到当前节里。
  final intro = <String>[];
  final sections = <PrivacySection>[];
  final outro = <String>[];
  var currentTitle = '';
  var currentParagraphs = <String>[];

  void closeSection() {
    if (currentTitle.isEmpty) return;
    sections.add(
      PrivacySection(currentTitle, List<String>.unmodifiable(currentParagraphs)),
    );
    currentTitle = '';
    currentParagraphs = <String>[];
  }

  for (final m in RegExp(
    r'<(h2|p)[^>]*>(.*?)</\1>',
    dotAll: true,
  ).allMatches(bodyPart)) {
    if (m.group(1) == 'p' && _isLinkOnly(m.group(2)!)) continue;
    final text = _text(m.group(2)!);
    if (text.isEmpty) continue;
    if (m.group(1) == 'h2') {
      closeSection();
      currentTitle = text;
    } else if (currentTitle.isEmpty) {
      // 还没遇到任何小标题：属于引言。
      intro.add(text);
    } else {
      currentParagraphs.add(text);
    }
  }
  closeSection();

  for (final m in RegExp(
    r'<p[^>]*>(.*?)</p>',
    dotAll: true,
  ).allMatches(tailPart)) {
    if (_isLinkOnly(m.group(1)!)) continue;
    final text = _text(m.group(1)!);
    if (text.isNotEmpty) outro.add(text);
  }

  if (title.isEmpty || sections.isEmpty) {
    throw const FormatException('privacy.html 抽不出标题或小节，站点结构变了？');
  }
  for (final s in sections) {
    if (s.paragraphs.isEmpty) {
      throw FormatException('privacy.html 的「${s.title}」一节没有正文');
    }
  }
  return PrivacyDocument(
    title: title,
    intro: List<String>.unmodifiable(intro),
    sections: List<PrivacySection>.unmodifiable(sections),
    outro: List<String>.unmodifiable(outro),
  );
}

/// 只由一个链接构成的段落是页面上的导航（例如结尾的“进入应用管理数据与权限”），
/// 不是条款正文；App 里本来就在应用内，照搬过去只会剩一行没头没尾的字。
bool _isLinkOnly(String html) {
  final withoutLinks = html.replaceAll(
    RegExp(r'<a\b[^>]*>.*?</a>', dotAll: true),
    '',
  );
  return _text(withoutLinks).isEmpty;
}

/// 把一段 HTML 变成纯文本：去掉标签、还原实体、压掉多余空白。
String _text(String html) {
  final withoutTags = html.replaceAll(RegExp(r'<[^>]*>'), '');
  final decoded = withoutTags.replaceAllMapped(RegExp(r'&(#?[a-zA-Z0-9]+);'), (m) {
    final name = m.group(1)!;
    if (name.startsWith('#x') || name.startsWith('#X')) {
      return String.fromCharCode(int.parse(name.substring(2), radix: 16));
    }
    if (name.startsWith('#')) {
      return String.fromCharCode(int.parse(name.substring(1)));
    }
    final known = _namedEntities[name];
    if (known == null) {
      throw FormatException('privacy.html 里出现了没登记的实体 &$name;');
    }
    return known;
  });
  return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 内容的指纹（FNV-1a 64 位，只是个版本标记，不是密码学摘要）。
String privacyFingerprint(String html) {
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  for (final byte in _utf8(html)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

List<int> _utf8(String s) {
  final out = <int>[];
  for (final rune in s.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune < 0x800) {
      out.add(0xC0 | (rune >> 6));
      out.add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      out.add(0xE0 | (rune >> 12));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    } else {
      out.add(0xF0 | (rune >> 18));
      out.add(0x80 | ((rune >> 12) & 0x3F));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    }
  }
  return out;
}

String _literal(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}

String _stringList(String name, List<String> items, String comment) {
  final b = StringBuffer()
    ..writeln('/// $comment')
    ..writeln('const List<String> $name = [');
  for (final item in items) {
    b.writeln('  ${_literal(item)},');
  }
  b.writeln('];');
  return b.toString();
}

/// 渲染成 lib/privacy_policy_text.dart 的完整内容。
/// 必须是纯函数：测试会重新渲染一次再和已提交的文件逐字节比对。
String renderPrivacyPolicyDart(String html) {
  final doc = parsePrivacyPolicy(html);
  final b = StringBuffer()
    ..writeln('// 本文件由 tool/gen_privacy_text.dart 生成，不要手改。')
    ..writeln('//')
    ..writeln('// 唯一事实来源：website/privacy.html（https://ddlkiller.com/privacy.html）。')
    ..writeln('// 改隐私说明请改那个文件，然后重新生成：')
    ..writeln('//   cd app && dart run tool/gen_privacy_text.dart')
    ..writeln('// 两边不一致时 test/privacy_policy_test.dart 会失败。')
    ..writeln()
    ..writeln('// 抽取自的 website/privacy.html 指纹（FNV-1a 64 位，手工核对版本用）。')
    ..writeln('const String kPrivacyPolicySourceFingerprint =')
    ..writeln("    '${privacyFingerprint(html)}';")
    ..writeln()
    ..writeln('/// 隐私说明的标题，取自网站上的 <h1>。')
    ..writeln('const String kPrivacyPolicyTitle = ${_literal(doc.title)};')
    ..writeln()
    ..writeln('/// 隐私说明里的一节：小标题加它下面的段落。')
    ..writeln('class PrivacySection {')
    ..writeln('  final String title;')
    ..writeln('  final List<String> paragraphs;')
    ..writeln('  const PrivacySection(this.title, this.paragraphs);')
    ..writeln('}')
    ..writeln();
  b.write(_stringList('kPrivacyPolicyIntro', doc.intro, '第一个小标题之前的引言。'));
  b.writeln();
  b
    ..writeln('/// 正文各节，顺序与网站上一致。')
    ..writeln('const List<PrivacySection> kPrivacyPolicySections = [');
  for (final s in doc.sections) {
    b.writeln('  PrivacySection(');
    b.writeln('    ${_literal(s.title)},');
    b.writeln('    [');
    for (final p in s.paragraphs) {
      b.writeln('      ${_literal(p)},');
    }
    b.writeln('    ],');
    b.writeln('  ),');
  }
  b.writeln('];');
  b.writeln();
  b.write(_stringList('kPrivacyPolicyOutro', doc.outro, '最后一节之后的收尾段落。'));
  return b.toString();
}
