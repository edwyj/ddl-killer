import 'package:flutter/material.dart';

import '../privacy_policy_text.dart';

/// 打开《隐私说明》全文，读到底才允许点「同意」。
///
/// 注册前用它替代「勾选框旁边写一行小字」的做法：出境这件事写在正文里，
/// 而正文必须滑到底才能同意，所以同意的那一刻用户确实翻到过那一节。
///
/// 返回 true 只代表用户读完并点了「同意」；取消、返回键都是 false。
Future<bool> showPrivacyConsentDialog(BuildContext context) async {
  final agreed = await showDialog<bool>(
    context: context,
    // 点空白关掉会让人以为已经同意了，只能走按钮。返回键等同取消，返回 null。
    barrierDismissible: false,
    builder: (_) => const PrivacyConsentDialog(),
  );
  return agreed ?? false;
}

/// 隐私说明全文弹窗。公开是为了让 widget 测试能直接找到它。
class PrivacyConsentDialog extends StatefulWidget {
  /// 正文区高度。测试用它把整篇塞进一屏，验证"放得下就不该锁住同意"。
  @visibleForTesting
  final double? debugContentHeight;

  const PrivacyConsentDialog({super.key, this.debugContentHeight});

  @override
  State<PrivacyConsentDialog> createState() => _PrivacyConsentDialogState();
}

class _PrivacyConsentDialogState extends State<PrivacyConsentDialog> {
  final _scroll = ScrollController();

  /// 是否已经读到底。一旦到过底部就不再撤销——回头重看一段不该把「同意」又锁上。
  bool _reachedEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkScroll);
    // 一屏放得下时不会有任何滚动事件，得主动看一次布局结果，
    // 否则「同意」永远点不动——这道门就成了死路。
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkScroll());
  }

  @override
  void dispose() {
    _scroll.removeListener(_checkScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _checkScroll() {
    if (_reachedEnd || !mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    // maxScrollExtent <= 0 说明全文一屏就放完了，本身就等于"已经看到底"。
    final atEnd = position.maxScrollExtent <= 0 ||
        position.pixels >= position.maxScrollExtent - 8;
    if (atEnd) setState(() => _reachedEnd = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    // 桌面上别铺满整屏：一行太长的正文没人读得下去。窄屏交给父级约束去压。
    final height =
        widget.debugContentHeight ?? (size.height - 240).clamp(160.0, 560.0);

    return AlertDialog(
      title: const Text(kPrivacyPolicyTitle),
      // 底部留一点缝：正文是可滚动的，被裁切的那一行不要贴着按钮。
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      content: SizedBox(
        width: 520,
        height: height,
        child: Scrollbar(
          controller: _scroll,
          // 竖条一直显示：让人知道下面还有，而不是以为就这么点字。
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.only(right: 12),
            child: _text(theme),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          // 没读到底就点不动；按钮自己说明为什么，免得用户对着一个死按钮猜。
          onPressed:
              _reachedEnd ? () => Navigator.of(context).pop(true) : null,
          child: Text(_reachedEnd ? '同意' : '请下滑阅读到底部'),
        ),
      ],
    );
  }

  Widget _text(ThemeData theme) {
    final heading = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface,
    );
    final paragraph = TextStyle(
      fontSize: 13.5,
      height: 1.7,
      color: theme.colorScheme.onSurfaceVariant,
    );

    Widget block(String text, TextStyle style, {double bottom = 10}) => Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Text(text, style: style),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final text in kPrivacyPolicyIntro) block(text, paragraph, bottom: 14),
        for (final section in kPrivacyPolicySections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(section.title, style: heading),
          ),
          for (final text in section.paragraphs) block(text, paragraph),
        ],
        for (final text in kPrivacyPolicyOutro) block(text, paragraph),
      ],
    );
  }
}
