import 'package:flutter/material.dart';

import '../api.dart';

/// 修改昵称。保存成功 pop 返回新昵称(可能为空串 = 清除昵称)；取消返回 null。
class NicknameScreen extends StatefulWidget {
  const NicknameScreen({super.key, required this.current});

  final String current;

  @override
  State<NicknameScreen> createState() => _NicknameScreenState();
}

class _NicknameScreenState extends State<NicknameScreen> {
  late final TextEditingController _ctrl;
  bool _busy = false;
  String? _error;

  static const int _maxLen = 24; // 与后端校验一致

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = _ctrl.text.trim();
    if (v.length > _maxLen) {
      setState(() => _error = '昵称最多 $_maxLen 个字符');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.updateProfile(nickname: v);
      if (mounted) Navigator.of(context).pop(v);
    } on ApiException catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.message; });
    } catch (_) {
      if (mounted) setState(() { _busy = false; _error = '无法连接服务器'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('修改昵称')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ctrl,
            enabled: !_busy,
            autofocus: true,
            maxLength: _maxLen,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _save(),
            decoration: const InputDecoration(
              labelText: '昵称',
              hintText: '留空则显示用户名',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const CircularProgressIndicator(strokeWidth: 2)
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}
