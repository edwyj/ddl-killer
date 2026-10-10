import 'package:flutter/material.dart';
import '../api.dart';
import '../auth_store.dart';
import 'login_screen.dart';
import '../widgets/secret_text_field.dart';

class ChangePasswordScreen extends StatefulWidget { const ChangePasswordScreen({super.key}); @override State<ChangePasswordScreen> createState() => _ChangePasswordScreenState(); }
class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _old = TextEditingController(); final _new = TextEditingController(); final _confirm = TextEditingController();
  bool _busy = false; String? _error;
  @override void dispose() { _old.dispose(); _new.dispose(); _confirm.dispose(); super.dispose(); }
  Future<void> _submit() async {
    if (_new.text != _confirm.text) { setState(() => _error = '两次新密码不一致'); return; }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.instance.changePassword(_old.text, _new.text);
      Api.instance.offline.pauseForLogin();
      await AuthStore.clear();
      Api.instance.token = null; // 与 AuthStore 同步清掉内存 token，否则 home 判定仍视为已登录
      if (mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    } on ApiException catch (e) { setState(() { _busy = false; _error = e.message; }); }
    catch (_) { setState(() { _busy = false; _error = '无法连接服务器'; }); }
  }
  @override Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('修改密码')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SecretTextField(controller: _old, labelText: '原密码'),
        const SizedBox(height: 14),
        SecretTextField(controller: _new, labelText: '新密码', helperText:'至少 12 个字符；修改后所有设备需重新登录'),
        const SizedBox(height: 14),
        SecretTextField(controller: _confirm, labelText: '确认新密码'),
        if (_error != null) ...[const SizedBox(height: 12), Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))],
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _submit, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), child: _busy ? const CircularProgressIndicator(strokeWidth: 2) : const Text('确认修改')),
      ]));
  }
}
