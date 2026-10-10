import 'package:flutter/material.dart';

import '../api.dart';
import 'captcha_image.dart';

Future<({String id, String code})?> emailCaptchaDialog(
  BuildContext context,
) async {
  final captcha = await Api.instance.captcha();
  if (!context.mounted) return null;
  return showDialog<({String id, String code})>(
    context: context,
    builder: (_) => _EmailCaptcha(captcha: captcha),
  );
}

class _EmailCaptcha extends StatefulWidget {
  const _EmailCaptcha({required this.captcha});
  final ({String id, String svg}) captcha;
  @override
  State<_EmailCaptcha> createState() => _EmailCaptchaState();
}

class _EmailCaptchaState extends State<_EmailCaptcha> {
  final code = TextEditingController();
  late ({String id, String svg})? _captcha;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _captcha = widget.captcha;
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _captcha = null;
      _error = null;
    });
    try {
      final captcha = await Api.instance.captcha();
      if (!mounted) return;
      setState(() {
        _captcha = captcha;
        _loading = false;
        code.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '验证码加载失败，请点击图片重试';
      });
    }
  }

  void _continue() {
    final captcha = _captcha;
    if (_loading || captcha == null || code.text.trim().isEmpty) return;
    Navigator.pop(context, (id: captcha.id, code: code.text.trim()));
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('请输入图形验证码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('填写图中的字符后，我们就会发送验证邮件。'),
          const SizedBox(height: 16),
          CaptchaImage(
            svg: _captcha?.svg,
            loading: _loading,
            onRefresh: _refresh,
          ),
          const SizedBox(height: 6),
          Text(
            '看不清？点击图片换一张',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: code,
            autofocus: true,
            decoration: const InputDecoration(labelText: '图形验证码'),
            onSubmitted: (_) => _continue(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: !_loading && _captcha != null ? _continue : null,
        child: const Text('继续'),
      ),
    ],
  );
}
