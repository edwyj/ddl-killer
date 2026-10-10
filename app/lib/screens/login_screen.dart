import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../auth_store.dart';
import '../build_channel.dart';
import 'root_screen.dart';
import 'forgot_password_screen.dart';
import '../widgets/login_presentation.dart';
import '../widgets/privacy_consent_dialog.dart';
import '../widgets/secret_text_field.dart';
import '../widgets/captcha_image.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback? onLoggedIn;
  @visibleForTesting
  final bool? debugWebLayout;
  const LoginScreen({super.key, this.onLoggedIn, this.debugWebLayout});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool get _webLayout => widget.debugWebLayout ?? kIsWeb;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  final _cap = TextEditingController();
  final _email = TextEditingController(), _emailCode = TextEditingController();
  String? _emailRequestId;
  String _verifiedEmail = '';
  int _emailSeconds = 0;
  Timer? _emailTimer;
  bool _registering = false;
  bool _busy = false;
  bool _retain = true;

  /// 注册前必须同意《隐私说明》。老用户不受影响(只挡注册)。
  bool _consent = false;

  /// 本次注册流程里已经完整读过一遍：取消勾选后再勾回来不必重读，
  /// 否则误触一下就得把全文再看一次。
  bool _privacyRead = false;

  @override
  void initState() {
    super.initState();
    _email.addListener(() {
      if (_emailRequestId != null &&
          _email.text.trim().toLowerCase() != _verifiedEmail) {
        setState(() {
          _emailRequestId = null;
          _emailCode.clear();
        });
      }
    });
    _user.text = Api.instance.offline.username ?? '';
    _retain = Api.instance.offline.persistent;
  }

  String? _error;
  String? _notice;

  /// 当前图形验证码(服务端一次性，失败后必须重新拉取)。
  String? _capId;
  String? _capSvg;
  bool _capLoading = false;

  /// 验证码拉取失败的统一文案(拉取处与提交校验处共用)。
  static const _capLoadError = '验证码加载失败，请点击图片重试';

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _confirm.dispose();
    _cap.dispose();
    _emailTimer?.cancel();
    _email.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  /// 拉一张新的验证码；失败则清空并给出可见提示(用户可点图重试)。
  Future<void> _loadCaptcha() async {
    if (_capLoading) return;
    setState(() {
      _capLoading = true;
      _capId = null;
      _capSvg = null;
    });
    try {
      final c = await Api.instance.captcha();
      if (!mounted) return;
      setState(() {
        _capId = c.id;
        _capSvg = c.svg;
        _capLoading = false;
        _cap.clear();
        // 重新拿到码后，别再挂着上一次的"加载失败"
        if (_error == _capLoadError) _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _capId = null;
        _capSvg = null;
        _capLoading = false;
        _error = _capLoadError;
      });
    }
  }

  /// 打开所在渠道的完整下载页，先展示安装说明，再由用户下载。
  Future<void> _downloadApk() async {
    final uri = BuildChannel.downloadPage;
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开下载链接，请手动访问 ddlkiller.com')),
      );
    }
  }

  /// 点勾选框（或《隐私说明》）：先弹出全文，滑到底才能同意。
  /// 这也是「数据存储在境外」的告知与同意（PIPL 第 39 条）——那句话就在正文里。
  Future<void> _toggleConsent() async {
    if (_busy) return;
    if (_consent) {
      setState(() => _consent = false);
      return;
    }
    // 读过了就直接勾上；没读过才强制走一遍全文。
    if (!_privacyRead && !await showPrivacyConsentDialog(context)) return;
    if (!mounted) return;
    setState(() {
      _privacyRead = true;
      _consent = true;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final user = _user.text.trim();
    final pass = _pass.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = '请输入账号和密码');
      return;
    }
    // 注册前必须勾选：这一步同时是数据存储于境外的告知与同意(PIPL 第39条)。
    if (_registering && !_consent) {
      setState(() => _error = '请先阅读并同意《隐私说明》');
      return;
    }
    // 邮箱地址变化后需重新获取验证码，不能提交先前邮箱的请求。
    if (_registering &&
        (_emailRequestId == null || _emailCode.text.length != 6)) {
      setState(() => _error = '请先验证邮箱，并填写邮件中的6位验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // 注册是否已成功落到服务端。一旦成功，用户名就被占用了、验证码也被烧掉了，
    // 之后的登录失败绝不能把用户丢回注册表单(重试注册只会看到误导性的"用户名已被占用")。
    var registered = false;
    try {
      if (_registering) {
        if (pass != _confirm.text) {
          setState(() {
            _busy = false;
            _error = '两次输入的密码不一致';
          });
          return;
        }
        await Api.instance.register(
          user,
          pass,
          email: _verifiedEmail,
          requestId: _emailRequestId!,
          code: _emailCode.text.trim(),
        );
        registered = true;
      }
      try {
        await Api.instance.login(user, pass, retain: _retain);
      } catch (_) {
        // 登录态下失败：原样抛给下面的统一处理，行为不变。
        if (!registered) rethrow;
        // 注册已成功、只是紧接着的登录失败(网络抖动等)：切回登录态并让用户重登，
        // 清掉已作废的验证码，别让它被当成有效码再次提交。
        if (mounted) {
          setState(() {
            _busy = false;
            _registering = false;
            _capId = null;
            _capSvg = null;
            _error = null;
            _notice = '注册成功，请登录';
          });
          _cap.clear();
        }
        return;
      }
      await AuthStore.saveToken(Api.instance.token!);
      if (mounted) {
        if (widget.onLoggedIn != null) {
          widget.onLoggedIn!();
        } else {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const RootScreen()),
            (_) => false,
          );
        }
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '无法连接服务器,请检查网络';
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      LoginPresentation(registering: _registering, form: _form);

  Future<void> _sendRegistrationCode() async {
    if (_busy || _emailSeconds > 0) return;
    if (_capId == null || _capSvg == null || _cap.text.trim().isEmpty) {
      setState(() => _error = '请先填写图形验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _emailRequestId = null;
    });
    try {
      final email = _email.text.trim().toLowerCase();
      final r = await Api.instance.requestRegistrationEmail(
        email,
        _capId!,
        _cap.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _verifiedEmail = email;
        _emailRequestId = r['request_id'] as String;
        _emailSeconds = 60;
        _notice = r['message'] as String? ?? '验证码请求已提交。没有收到，请重试或联系开发者。';
      });
      _emailTimer?.cancel();
      _emailTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _emailSeconds--);
        if (_emailSeconds <= 0) t.cancel();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '暂时没能发送验证邮件，请稍后再试。');
    } finally {
      _cap.clear();
      await _loadCaptcha();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final username = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
    );
    if (username != null && mounted) {
      _user.text = username;
      _pass.clear();
      setState(() {
        _error = null;
        _notice = '密码已更新，用新密码登录就好。';
      });
    }
  }

  Widget _form(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        controller: _user,
        enabled: !_busy,
        decoration: InputDecoration(labelText: '账号', border: null),
      ),
      const SizedBox(height: 14),
      SecretTextField(
        controller: _pass,
        enabled: !_busy,
        border: null,
        labelText: '密码',
        onSubmitted: (_) => _submit(),
      ),
      if (_registering) ...[
        const SizedBox(height: 14),
        SecretTextField(
          controller: _confirm,
          enabled: !_busy,
          border: null,
          labelText: '确认密码',
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: '邮箱地址', border: null),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CaptchaImage(
              svg: _capSvg,
              loading: _capLoading,
              width: 132,
              height: 48,
              onRefresh: _busy ? null : _loadCaptcha,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _cap,
                enabled: !_busy,
                decoration: InputDecoration(labelText: '验证码', border: null),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy || _emailSeconds > 0 ? null : _sendRegistrationCode,
          child: Text(_emailSeconds > 0 ? '$_emailSeconds 秒后可重发' : '获取邮箱验证码'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _emailCode,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          decoration: const InputDecoration(
            labelText: '邮箱验证码',
            border: null,
            counterText: '',
          ),
        ),
      ],
      if (!_registering)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy ? null : _forgotPassword,
            child: const Text('忘记密码？'),
          ),
        ),
      if (_notice != null) ...[
        const SizedBox(height: 12),
        Text(
          _notice!,
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.redAccent),
        ),
      ],
      CheckboxListTile(
        controlAffinity: ListTileControlAffinity.leading,
        value: _retain,
        onChanged: _busy ? null : (v) => setState(() => _retain = v ?? true),
        contentPadding: EdgeInsets.zero,
        title: Text('在此设备启用离线数据', style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '断网时仍可使用；公共设备建议关闭，离开前请完成同步',
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
      // 只在注册时要求：登录不该追问老用户这件事。
      // 点勾选框会先弹出《隐私说明》全文，必须滑到底才能同意，
      // 所以同意的那一刻用户确实读到过"数据存储在境外"那一节（PIPL 第 39 条的告知与同意）。
      if (_registering) ...[
        const SizedBox(height: 4),
        CheckboxListTile(
          controlAffinity: ListTileControlAffinity.leading,
          value: _consent,
          onChanged: _busy ? null : (_) => _toggleConsent(),
          contentPadding: EdgeInsets.zero,
          title: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: '我已阅读并同意'),
                TextSpan(
                  text: '《隐私说明》',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 14),
          ),
          // 一个箭头，暗示点它不只是打勾、还会打开东西。
          secondary: Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: 18),
      LoginSubmitButton(
        busy: _busy,
        label: _registering ? '注册' : '登录',
        onPressed: _submit,
      ),
      const SizedBox(height: 8),
      if (!BuildChannel.beta)
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  final toRegister = !_registering;
                  setState(() {
                    _registering = toRegister;
                    _error = null;
                    _notice = null;
                  });
                  // 进注册态就换一张新的(登录态不需要验证码)
                  if (toRegister) _loadCaptcha();
                },
          child: Text(_registering ? '已有账号？去登录' : '创建一个账号'),
        ),
      // 仅网页端提供安卓版下载入口(手机上装的就是 app 本身)
      if (_webLayout) ...[
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _downloadApk,
          icon: const Icon(Icons.download, size: 18),
          label: Text(BuildChannel.beta ? '下载 Android 测试版' : '下载 Android 版'),
        ),
      ],
    ],
  );
}
