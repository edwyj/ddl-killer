import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/secret_text_field.dart';

import '../api.dart';
import '../models/mcp_connection.dart';

const kMcpHelpUrl = 'https://ddlkiller.com/mcp-help.html';

abstract class McpConnectionsGateway {
  Future<List<McpConnection>> clients();
  Future<List<McpAuditEntry>> audit();
  Future<CreatedMcpToken> create({
    required String name,
    required List<String> scopes,
    required DateTime expiresAt,
    required String password,
  });
  Future<void> revoke(String id, String password);
}

class ApiMcpConnectionsGateway implements McpConnectionsGateway {
  @override
  Future<List<McpConnection>> clients() => Api.instance.mcpClients();
  @override
  Future<List<McpAuditEntry>> audit() => Api.instance.mcpAudit();
  @override
  Future<CreatedMcpToken> create({
    required String name,
    required List<String> scopes,
    required DateTime expiresAt,
    required String password,
  }) => Api.instance.createMcpClient(
    name: name,
    scopes: scopes,
    expiresAt: expiresAt,
    password: password,
  );
  @override
  Future<void> revoke(String id, String password) =>
      Api.instance.revokeMcpClient(id, password);
}

class McpConnectionsScreen extends StatefulWidget {
  final McpConnectionsGateway? gateway;
  const McpConnectionsScreen({super.key, this.gateway});
  @override
  State<McpConnectionsScreen> createState() => _McpConnectionsScreenState();
}

class _McpConnectionsScreenState extends State<McpConnectionsScreen> {
  late final McpConnectionsGateway api =
      widget.gateway ?? ApiMcpConnectionsGateway();
  List<McpConnection>? clients;
  List<McpAuditEntry>? audit;
  String? error;
  static const planning = [
    'mcp:read',
    'mcp:tasks:write',
    'mcp:schedule:draft',
    'mcp:schedule:apply',
  ];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await Future.wait([api.clients(), api.audit()]);
      if (mounted) {
        setState(() {
          clients = result[0] as List<McpConnection>;
          audit = result[1] as List<McpAuditEntry>;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _create() async {
    final name = TextEditingController(), password = TextEditingController();
    var preset = 'planning';
    var days = 90;
    var scopes = [...planning];
    String? dialogError;
    bool busy = false;
    final made = await showDialog<CreatedMcpToken>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('创建手动令牌'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('mcp-name'),
                    controller: name,
                    decoration: const InputDecoration(labelText: '连接名称'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: preset,
                    decoration: const InputDecoration(labelText: '权限预设'),
                    items: const [
                      DropdownMenuItem(value: 'readonly', child: Text('只读')),
                      DropdownMenuItem(
                        value: 'planning',
                        child: Text('任务与规划（推荐）'),
                      ),
                      DropdownMenuItem(value: 'full', child: Text('完整管理')),
                    ],
                    onChanged: (v) => setLocal(() {
                      preset = v!;
                      scopes = switch (v) {
                        'readonly' => ['mcp:read'],
                        'full' => [
                          'mcp:read',
                          'mcp:tasks:write',
                          'mcp:schedule:draft',
                          'mcp:schedule:apply',
                          'mcp:delete',
                          'mcp:purge',
                        ],
                        _ => [...planning],
                      };
                    }),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: days,
                    decoration: const InputDecoration(labelText: '有效期'),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 天')),
                      DropdownMenuItem(value: 90, child: Text('90 天')),
                    ],
                    onChanged: (v) => setLocal(() => days = v!),
                  ),
                  ExpansionTile(
                    title: const Text('高级权限'),
                    children: [
                      for (final s in const [
                        'mcp:read',
                        'mcp:tasks:write',
                        'mcp:schedule:draft',
                        'mcp:schedule:apply',
                        'mcp:delete',
                        'mcp:purge',
                      ])
                        CheckboxListTile(
                          dense: true,
                          title: Text(s),
                          value: scopes.contains(s),
                          onChanged: (v) => setLocal(() {
                            if (v == true) {
                              if (!scopes.contains(s)) scopes.add(s);
                            } else {
                              scopes.remove(s);
                            }
                          }),
                        ),
                    ],
                  ),
                  SecretTextField(
                    key: const ValueKey('mcp-password'),
                    controller: password,
                    labelText: '输入密码确认',
                    border: const UnderlineInputBorder(),
                  ),
                  if (dialogError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        dialogError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty || password.text.isEmpty) {
                        setLocal(() => dialogError = '请填写连接名称和密码');
                        return;
                      }
                      setLocal(() {
                        busy = true;
                        dialogError = null;
                      });
                      try {
                        final value = await api.create(
                          name: name.text.trim(),
                          scopes: scopes,
                          expiresAt: DateTime.now().add(Duration(days: days)),
                          password: password.text,
                        );
                        if (context.mounted) Navigator.pop(context, value);
                      } catch (e) {
                        setLocal(() {
                          busy = false;
                          dialogError = '$e';
                        });
                      }
                    },
              child: const Text('创建令牌'),
            ),
          ],
        ),
      ),
    );
    if (made == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('令牌只显示这一次'),
        content: SelectableText(made.token),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: made.token)),
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我已保存'),
          ),
        ],
      ),
    );
    await _load();
  }

  Future<void> _openHelp() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(kMcpHelpUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法打开教程，请访问 ddlkiller.com/mcp-help.html'),
        ),
      );
    }
  }

  Future<void> _revoke(McpConnection item) async {
    final p = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销连接？'),
        content: SecretTextField(
          key: const ValueKey('revoke-password'),
          controller: p,
          labelText: '输入密码确认',
          border: const UnderlineInputBorder(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('立即撤销'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await api.revoke(item.id, p.text);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('智能体连接')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.hub_outlined,
                    color: theme.colorScheme.primary,
                    size: 30,
                  ),
                  const SizedBox(height: 12),
                  Text('让你信任的智能体帮你管理计划', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('连接后，智能体只能在你允许的权限范围内读取或修改数据。可随时撤销。'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('MCP 地址', style: theme.textTheme.titleMedium),
            const SelectableText('https://ddlkiller.com/mcp'),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _openHelp,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('查看连接教程'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_link),
              label: const Text('创建手动令牌'),
            ),
            const SizedBox(height: 24),
            Text('现有连接', style: theme.textTheme.titleMedium),
            if (error != null)
              Text(error!, style: TextStyle(color: theme.colorScheme.error))
            else if (clients == null)
              const Center(child: CircularProgressIndicator())
            else if (clients!.isEmpty)
              const Text('还没有连接')
            else
              for (final c in clients!)
                Card(
                  child: ListTile(
                    leading: Icon(
                      c.clientType == 'oauth'
                          ? Icons.auto_awesome
                          : Icons.key_outlined,
                    ),
                    title: Text(c.name),
                    subtitle: Text(
                      '${c.scopes.length} 项权限 · ${c.lastUsedAt == null ? "尚未使用" : "最近使用 ${c.lastUsedAt}"}',
                    ),
                    trailing: IconButton(
                      key: ValueKey('revoke-${c.id}'),
                      tooltip: '撤销',
                      onPressed: () => _revoke(c),
                      icon: const Icon(Icons.link_off),
                    ),
                  ),
                ),
            const SizedBox(height: 24),
            Text('最近活动', style: theme.textTheme.titleMedium),
            if (audit != null)
              for (final a in audit!.take(10))
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text('${a.clientName} · ${a.toolName}'),
                  subtitle: Text(a.resultCode),
                ),
          ],
        ),
      ),
    );
  }
}
