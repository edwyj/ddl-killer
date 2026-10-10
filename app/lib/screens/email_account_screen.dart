import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../widgets/secret_text_field.dart';
import '../widgets/email_captcha_dialog.dart';

class EmailAccountActions {
  const EmailAccountActions({
    required this.status,
    required this.request,
    required this.confirm,
  });
  final Future<Map<String, dynamic>> Function() status;
  final Future<Map<String, dynamic>> Function(
    String email,
    String? password,
    String? captchaId,
    String? captchaCode,
  )
  request;
  final Future<String?> Function(bool reset, Map<String, dynamic> body) confirm;
  static final live = EmailAccountActions(
    status: Api.instance.accountEmail,
    request: (email, password, id, code) => Api.instance.requestEmailCode(
      email,
      password: password,
      captchaId: id,
      captchaCode: code,
    ),
    confirm: (reset, body) async {
      if (reset) return Api.instance.resetPassword(body);
      await Api.instance.bindEmail(body);
      return null;
    },
  );
}

class EmailAccountScreen extends StatefulWidget {
  const EmailAccountScreen({super.key, this.reset = false, this.actions});
  final bool reset;
  final EmailAccountActions? actions;
  @override
  State<EmailAccountScreen> createState() => _EmailAccountScreenState();
}

class _EmailAccountScreenState extends State<EmailAccountScreen> {
  EmailAccountActions get actions => widget.actions ?? EmailAccountActions.live;
  final _email = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController(),
      _code = TextEditingController(),
      _oldCode = TextEditingController();
  bool _bound = false, _loading = true, _ready = false, _busy = false;
  String? _masked, _error, _message, _requestId, _oldRequestId;
  String _requestedEmail = '', _requestedPassword = '';
  int _seconds = 0;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _email.addListener(_invalidate);
    if (!widget.reset) _password.addListener(_invalidate);
    _load();
  }

  void _invalidate() {
    if (_requestId != null &&
        (_email.text.trim().toLowerCase() != _requestedEmail ||
            (!widget.reset && _password.text != _requestedPassword))) {
      setState(() {
        _requestId = null;
        _oldRequestId = null;
        _code.clear();
        _oldCode.clear();
        _message = null;
      });
    }
  }

  Future<void> _load() async {
    if (widget.reset) {
      _loading = false;
      _ready = true;
      return;
    }
    try {
      final r = await actions.status();
      if (mounted) {
        setState(() {
          _bound = r['bound'] == true;
          _masked = r['masked_email'] as String?;
          _loading = false;
          _ready = r['enabled'] != false;
          _error = _ready ? null : '邮箱验证服务暂时不可用，请稍后再试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '邮箱信息暂时没能加载，请联网后重试。';
        });
      }
    }
  }

  void _cooldown(int seconds) {
    _timer?.cancel();
    _seconds = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _seconds--);
      if (_seconds <= 0) t.cancel();
    });
  }

  Future<void> _send() async {
    if (_busy || _seconds > 0) return;
    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@')) {
      setState(() => _error = '请填写有效的邮箱地址');
      return;
    }
    if (!widget.reset && _password.text.isEmpty) {
      setState(() => _error = '请先填写当前密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _requestId = null;
      _oldRequestId = null;
    });
    try {
      final captcha = widget.reset ? await emailCaptchaDialog(context) : null;
      if (widget.reset && captcha == null) return;
      final r = await actions.request(
        email,
        widget.reset ? null : _password.text,
        captcha?.id,
        captcha?.code,
      );
      if (!mounted) return;
      setState(() {
        _requestedEmail = email;
        _requestedPassword = _password.text;
        _requestId = r['request_id'] as String;
        _oldRequestId = r['old_request_id'] as String?;
        _message = r['message'] as String?;
        _cooldown((r['resend_after'] as num?)?.toInt() ?? 60);
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          final wait = e.details?['retryAfterSeconds'];
          if (wait is num) _cooldown(wait.toInt());
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时没能发送邮件，请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_requestId == null) {
      setState(() => _error = '请先获取邮箱验证码');
      return;
    }
    if (_code.text.length != 6 ||
        (_bound && !widget.reset && _oldCode.text.length != 6)) {
      setState(() => _error = '请填写邮件中的6位验证码');
      return;
    }
    if (widget.reset && _password.text != _confirm.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'email': _requestedEmail,
        'request_id': _requestId,
        'code': _code.text,
      };
      if (widget.reset) {
        body['new_password'] = _password.text;
        final username = await actions.confirm(true, body);
        if (mounted) Navigator.pop(context, username);
      } else {
        body.addAll({
          'password': _password.text,
          if (_oldRequestId != null) 'old_request_id': _oldRequestId,
          if (_oldRequestId != null) 'old_code': _oldCode.text,
        });
        await actions.confirm(false, body);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('邮箱绑定好了，以后可以用它找回密码。')));
          Navigator.pop(context, true);
        }
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _password, _confirm, _code, _oldCode]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _codeField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.reset ? '找回密码' : '邮箱')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.reset ? '忘记密码也没关系' : '为账号留一份安心',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  widget.reset
                      ? '填写你已绑定并验证的邮箱，收到验证码后就可以设置新密码。尚未绑定邮箱的账号暂时无法自助找回，请联系开发者处理。'
                      : _bound
                      ? '当前邮箱：${_masked ?? ''}。更换时需要确认当前密码，并验证原邮箱和新邮箱；原邮箱无法收信时，请联系开发者核实处理。'
                      : '绑定常用邮箱后，即使忘记密码，也能把账号找回来。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                if (!widget.reset) ...[
                  const SizedBox(height: 8),
                  Text(
                    '一个邮箱只能绑定一个账号。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_loading) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 24),
                if (!widget.reset) ...[
                  SecretTextField(
                    controller: _password,
                    labelText: '当前密码',
                    enabled: !_busy,
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '邮箱地址',
                    helperText: widget.reset
                        ? null
                        : _bound
                        ? '填写新的邮箱地址'
                        : '请使用你能正常收信的邮箱',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy || _loading || !_ready || _seconds > 0
                      ? null
                      : _send,
                  icon: const Icon(Icons.mail_outline),
                  label: Text(
                    _seconds > 0
                        ? '$_seconds 秒后可重发'
                        : _busy
                        ? '正在处理…'
                        : '获取验证码',
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _message!,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ],
                const SizedBox(height: 16),
                _codeField(
                  _code,
                  widget.reset
                      ? '邮箱验证码'
                      : _bound
                      ? '新邮箱验证码'
                      : '邮箱验证码',
                ),
                if (_bound && !widget.reset) ...[
                  const SizedBox(height: 16),
                  _codeField(_oldCode, '原邮箱验证码'),
                ],
                if (widget.reset) ...[
                  const SizedBox(height: 16),
                  SecretTextField(
                    controller: _password,
                    labelText: '新密码',
                    enabled: !_busy,
                    helperText: '至少12个字符，建议组合使用英文字母、数字和符号',
                  ),
                  const SizedBox(height: 16),
                  SecretTextField(
                    controller: _confirm,
                    labelText: '确认新密码',
                    enabled: !_busy,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  if (!widget.reset && !_busy && !_ready)
                    TextButton(onPressed: _load, child: const Text('重新加载邮箱信息')),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy || _loading || !_ready ? null : _submit,
                  child: Text(
                    _busy
                        ? '正在处理…'
                        : widget.reset
                        ? '设置新密码'
                        : _bound
                        ? '确认更换邮箱'
                        : '确认绑定邮箱',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '验证码10分钟内有效。没有收到，请重试或联系开发者。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
