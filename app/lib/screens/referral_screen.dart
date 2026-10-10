import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../community_state.dart';
import 'ai_invite_screen.dart';

class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});
  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await communityState.refreshReferral();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '邀请信息暂时无法加载，请联网后重试',
        );
      }
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(
      ClipboardData(
        text:
            '一起试试 DDL Killer 吧 🎀\nhttps://ddlkiller.com\n我的邀请注册码：$code\n注册后 7 天内，在“我的 → 兑换码”使用，双方各获得 7 天、每天 6 次的 AI 体验奖励。',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('邀请文案已复制，可以发给朋友啦')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('邀请朋友')),
    body: ListenableBuilder(
      listenable: communityState,
      builder: (context, _) {
        final info = communityState.referral;
        final cs = Theme.of(context).colorScheme;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '把好用的安排，分享给朋友。',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text('朋友注册后使用你的邀请注册码，你们都会收到一张邀请周卡：7 天，每天共 6 次 AI 安排。'),
              const SizedBox(height: 28),
              if (info == null && _error == null)
                const Center(child: CircularProgressIndicator()),
              if (info != null) ...[
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      const Text('你的邀请注册码'),
                      const SizedBox(height: 16),
                      SelectableText(
                        info['code'] as String,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => _copy(info['code'] as String),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制邀请文案'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '本月成功邀请 ${info['earnedThisMonth']} 人${info['monthlyLimit'] == 0 ? '' : '，奖励上限 ${info['monthlyLimit']} 份'}',
                ),
                const SizedBox(height: 12),
              ],
              const Text(
                '朋友注册后 7 天内可兑换，每位新用户只能使用一个邀请注册码。你的码可以分享给多位朋友。\n\n奖励会发送到双方的“消息”，领取后开始计时。如果你还有其他体验卡，会使用较高的每日次数；次数和有效期不会叠加。',
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiInviteScreen()),
                ),
                child: const Text('我收到一个兑换码'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: cs.error)),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ],
          ),
        );
      },
    ),
  );
}
