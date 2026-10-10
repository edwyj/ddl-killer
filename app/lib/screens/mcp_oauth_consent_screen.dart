import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';

class McpOAuthRequest {
  final String requestId, clientName;
  final List<String> scopes;
  const McpOAuthRequest({
    required this.requestId,
    required this.clientName,
    required this.scopes,
  });
}

abstract class McpOAuthGateway {
  Future<McpOAuthRequest> request(String requestId);
  Future<Uri> approve(String requestId, List<String> scopes);
  Future<Uri> deny(String requestId);
}

class ApiMcpOAuthGateway implements McpOAuthGateway {
  @override
  Future<McpOAuthRequest> request(String id) async {
    final r = await Api.instance.oauthRequest(id);
    return McpOAuthRequest(
      requestId: r['requestId'] as String,
      clientName: r['clientName'] as String,
      scopes: List<String>.from(r['scopes'] as List),
    );
  }

  @override
  Future<Uri> approve(String id, List<String> scopes) =>
      Api.instance.approveOauth(id, scopes);
  @override
  Future<Uri> deny(String id) => Api.instance.denyOauth(id);
}

class McpOAuthConsentScreen extends StatefulWidget {
  final String requestId;
  final McpOAuthGateway? gateway;
  final void Function(Uri)? onRedirect;
  const McpOAuthConsentScreen({
    super.key,
    required this.requestId,
    this.gateway,
    this.onRedirect,
  });
  @override
  State<McpOAuthConsentScreen> createState() => _McpOAuthConsentScreenState();
}

class _McpOAuthConsentScreenState extends State<McpOAuthConsentScreen> {
  late final api = widget.gateway ?? ApiMcpOAuthGateway();
  McpOAuthRequest? request;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    api
        .request(widget.requestId)
        .then((v) {
          if (mounted) setState(() => request = v);
        })
        .catchError((e) {
          if (mounted) setState(() => error = '$e');
        });
  }

  String label(String s) => switch (s) {
    'mcp:read' => '查看你的清单、任务、课程和日程',
    'mcp:tasks:write' => '创建和修改任务',
    'mcp:schedule:draft' => '生成待确认的排期草案',
    'mcp:schedule:apply' => '应用你确认的排期',
    'mcp:delete' => '将任务移入回收站',
    'mcp:purge' => '永久删除数据',
    _ => s,
  };
  Future<void> act(bool allow) async {
    if (request == null) return;
    setState(() => busy = true);
    try {
      final uri = allow
          ? await api.approve(widget.requestId, request!.scopes)
          : await api.deny(widget.requestId);
      if (widget.onRedirect != null) {
        widget.onRedirect!(uri);
      } else {
        await launchUrl(uri, webOnlyWindowName: '_self');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (error != null) {
      content = Text(error!);
    } else if (request == null) {
      content = const CircularProgressIndicator();
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.verified_user_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            request!.clientName,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text('请确认它可以做什么：'),
          const SizedBox(height: 12),
          for (final s in request!.scopes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                s == 'mcp:purge'
                    ? Icons.warning_amber
                    : Icons.check_circle_outline,
              ),
              title: Text(label(s)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => act(false),
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : () => act(true),
                  child: const Text('允许连接'),
                ),
              ),
            ],
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('确认智能体连接')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(padding: const EdgeInsets.all(24), child: content),
        ),
      ),
    );
  }
}
