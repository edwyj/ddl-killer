import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../community_state.dart';
import '../ai_assistant_state.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(communityState.refreshMessages());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('消息'),
      actions: [
        IconButton(
          tooltip: '刷新消息',
          onPressed: communityState.refreshMessages,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: communityState,
      builder: (context, _) => RefreshIndicator(
        onRefresh: communityState.refreshMessages,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (communityState.messageError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  communityState.messageError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (!communityState.messagesLoaded &&
                communityState.messageError == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (communityState.messagesLoaded &&
                communityState.messages.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.mark_email_read_outlined, size: 40),
                    SizedBox(height: 16),
                    Text('还没有新消息。收到回复或奖励时，我们会在这里告诉你。'),
                  ],
                ),
              ),
            for (final m in communityState.messages)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  leading: Badge(
                    isLabelVisible: m['read'] != true,
                    child: Icon(
                      m['reward'] != null
                          ? Icons.card_giftcard_outlined
                          : Icons.mail_outline,
                    ),
                  ),
                  title: Text(
                    m['title'] as String,
                    style: TextStyle(
                      fontWeight: m['read'] == true
                          ? FontWeight.w500
                          : FontWeight.w700,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m['body'] as String,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          DateFormat('M月d日 HH:mm').format(
                            DateTime.parse(m['createdAt'] as String).toLocal(),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MessageDetailScreen(
                        message: Map<String, dynamic>.from(m),
                      ),
                    ),
                  ),
                ),
              ),
            if (communityState.hasMoreMessages)
              TextButton(
                onPressed: communityState.loadingMoreMessages
                    ? null
                    : communityState.loadMoreMessages,
                child: Text(
                  communityState.loadingMoreMessages ? '正在加载…' : '查看更早的消息',
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class MessageDetailScreen extends StatefulWidget {
  const MessageDetailScreen({super.key, required this.message});
  final Map<String, dynamic> message;
  @override
  State<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends State<MessageDetailScreen> {
  late Map<String, dynamic>? _reward;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _reward = widget.message['reward'] as Map<String, dynamic>?;
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      await Api.instance.communityPost(
        '/api/messages/${widget.message['id']}/read',
        {},
      );
      communityState.markRead(widget.message['id'] as int);
      unawaited(communityState.refreshMessagesAfterMutation());
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '阅读状态尚未同步，联网后可重试',
        );
      }
    }
  }

  Future<void> _claim() async {
    final reward = _reward;
    if (_busy || reward == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('领取${reward['name']}'),
        content: Text(
          '领取后开始 ${reward['days']} 天体验，每天共 ${reward['dailyLimit']} 次。\n\n如果你还有其他体验卡，会使用较高的每日次数；次数和有效期不会叠加，今天已用的次数也会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后领取'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认领取'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await Api.instance.communityPost(
        '/api/rewards/${reward['id']}/claim',
        {},
      );
      if (!mounted) return;
      setState(
        () => _reward = Map<String, dynamic>.from(result['reward'] as Map),
      );
      await communityState.refreshMessagesAfterMutation();
      try {
        await aiAssistantState.refreshAfterMutation();
      } catch (_) {
        /* Entitlement is already safely claimed. */
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '暂时无法领取，请联网后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reward = _reward;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('消息详情')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.message['title'] as String,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    DateFormat('yyyy年M月d日 HH:mm').format(
                      DateTime.parse(widget.message['createdAt'] as String)
                          .toLocal(),
                    ),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  SelectableText(
                    widget.message['body'] as String,
                    style: const TextStyle(fontSize: 16, height: 1.8),
                  ),
                  if (reward != null) ...[
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            Icons.card_giftcard_outlined,
                            color: cs.onPrimaryContainer,
                            size: 30,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            reward['name'] as String,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${reward['days']} 天 · 每天 ${reward['dailyLimit']} 次',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onPrimaryContainer),
                          ),
                          const SizedBox(height: 16),
                          if (reward['status'] == 'available')
                            FilledButton(
                              onPressed: _busy ? null : _claim,
                              child: Text(
                                _busy ? '正在领取…' : '领取${reward['name']}',
                              ),
                            )
                          else
                            Text(
                              {
                                    'claimed': '已领取',
                                    'expired': '已过领取期限',
                                    'revoked': '奖励已撤销',
                                  }[reward['status']] ??
                                  '奖励信息正在更新，请稍后刷新看看。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: cs.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          const SizedBox(height: 10),
                          Text(
                            '${reward['status'] == 'claimed' ? '体验到期' : '领取截止'}：${DateFormat('M月d日 HH:mm').format(DateTime.parse((reward['status'] == 'claimed' ? reward['expiresAt'] : reward['redeemBefore']) as String).toLocal())}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: cs.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
