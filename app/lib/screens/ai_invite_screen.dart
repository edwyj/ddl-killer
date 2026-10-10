import 'package:flutter/material.dart';

import '../api.dart';
import '../ai_assistant_state.dart';
import '../community_state.dart';

class AiInviteScreen extends StatefulWidget {
  const AiInviteScreen({super.key, this.preview, this.redeem, this.refresh});
  final Future<Map<String, dynamic>> Function(String)? preview;
  final Future<void> Function(String)? redeem;
  final Future<void> Function()? refresh;
  @override
  State<AiInviteScreen> createState() => _AiInviteScreenState();
}

class _AiInviteScreenState extends State<AiInviteScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _redeemed = false;
  bool _isReferral = false;
  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请填写兑换码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_redeemed) {
        final preview = await (widget.preview ?? Api.instance.previewAiInvite)(
          code,
        );
        if (!mounted) return;
        final expiry = DateTime.parse(preview['expiresAt'] as String).toLocal();
        final active = preview['active'] as List? ?? [];
        final referral = preview['kind'] == 'referral';
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              preview['alreadyRedeemed'] == true
                  ? '这个兑换码已经使用过啦'
                  : '确认兑换${preview['name']}',
            ),
            content: SingleChildScrollView(
              child: Text(
                referral
                    ? '兑换成功后，你和邀请者双方各收到一张邀请周卡：${preview['days']} 天，每天共 ${preview['dailyLimit']} 次。\n\n奖励发送到“消息”，领取后开始计时，需在 7 天内领取。每位新用户只能使用一个邀请注册码。如果你还有其他体验卡，会使用较高的每日次数；次数和有效期不会叠加。'
                    : '每天共 ${preview['dailyLimit']} 次AI 安排，有效期 ${preview['days']} 天。\n预计到期：${expiry.year}/${expiry.month}/${expiry.day} ${expiry.hour.toString().padLeft(2, '0')}:${expiry.minute.toString().padLeft(2, '0')}\n\n兑换后立即生效，当天已用次数保留，服务繁忙时可能需要稍等一下。${active.isNotEmpty ? '\n你还有其他体验卡，会使用较高的每日次数；次数和有效期不会叠加。' : ''}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认兑换'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await (widget.redeem ?? Api.instance.redeemAiInvite)(code);
        _isReferral = referral;
        _redeemed = true;
      }
      await (widget.refresh ??
          () async {
            if (_isReferral) {
              await communityState.refreshMessages();
            } else {
              await aiAssistantState.refreshAfterMutation();
            }
          })();
      if (mounted) {
        if (_isReferral) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('邀请兑换成功，双方奖励已发送到“消息”，领取后生效')),
          );
        }
        Navigator.pop(context, true);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _redeemed
              ? '已兑换成功，额度刷新失败。请重试刷新。'
              : '暂时无法连接，请联网后重试。已填写的兑换码会保留。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('兑换码')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '领取 AI 计划助手体验额度',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text('输入朋友的邀请注册码或收到的奖励码，确认前会展示用途、额度和有效期。兑换需要联网。'),
                const SizedBox(height: 24),
                TextField(
                  controller: _code,
                  enabled: !_busy && !_redeemed,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '兑换码',
                    hintText: '粘贴你收到的码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(
                    _busy
                        ? '正在处理…'
                        : _redeemed
                        ? '刷新额度'
                        : '查看并兑换',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
