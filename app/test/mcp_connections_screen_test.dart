import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/models/mcp_connection.dart';
import 'package:plan_app/screens/mcp_connections_screen.dart';

class FakeMcpGateway implements McpConnectionsGateway {
  bool failCreate = false;
  String? createdName;
  List<String>? createdScopes;
  String? revoked;
  @override
  Future<List<McpConnection>> clients() async => [
    McpConnection(
      id: 'one',
      name: 'Claude',
      clientType: 'oauth',
      scopes: const ['mcp:read'],
      expiresAt: DateTime(2030),
      createdAt: DateTime(2026),
    ),
  ];
  @override
  Future<List<McpAuditEntry>> audit() async => [
    McpAuditEntry(
      clientName: 'Claude',
      toolName: 'plan_view_tasks',
      resultCode: 'OK',
      createdAt: DateTime(2026),
    ),
  ];
  @override
  Future<CreatedMcpToken> create({
    required String name,
    required List<String> scopes,
    required DateTime expiresAt,
    required String password,
  }) async {
    createdName = name;
    createdScopes = scopes;
    if (failCreate) throw Exception('创建失败');
    return CreatedMcpToken(
      token: 'ddl_mcp_secret',
      client: (await clients()).first,
    );
  }

  @override
  Future<void> revoke(String id, String password) async {
    revoked = id;
  }
}

void main() {
  Future<void> pump(WidgetTester tester, FakeMcpGateway api) async {
    await tester.pumpWidget(
      MaterialApp(home: McpConnectionsScreen(gateway: api)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('令牌只展示一次，关闭后不进入连接列表', (tester) async {
    final api = FakeMcpGateway();
    await pump(tester, api);
    await tester.tap(find.text('创建手动令牌'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('mcp-name')), 'Codex');
    await tester.enterText(
      find.byKey(const ValueKey('mcp-password')),
      'password',
    );
    await tester.tap(find.text('创建令牌'));
    await tester.pumpAndSettle();
    expect(find.text('ddl_mcp_secret'), findsOneWidget);
    await tester.tap(find.text('我已保存'));
    await tester.pumpAndSettle();
    expect(find.text('ddl_mcp_secret'), findsNothing);
    expect(find.textContaining('ddl_mcp_'), findsNothing);
    expect(
      api.createdScopes,
      containsAll([
        'mcp:read',
        'mcp:tasks:write',
        'mcp:schedule:draft',
        'mcp:schedule:apply',
      ]),
    );
  });
  testWidgets('创建失败保留输入，撤销需确认', (tester) async {
    final api = FakeMcpGateway()..failCreate = true;
    await pump(tester, api);
    await tester.tap(find.text('创建手动令牌'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('mcp-name')), '保留我');
    await tester.enterText(find.byKey(const ValueKey('mcp-password')), 'pw');
    await tester.tap(find.text('创建令牌'));
    await tester.pumpAndSettle();
    expect(find.text('保留我'), findsOneWidget);
    expect(find.textContaining('创建失败'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('revoke-one')));
    await tester.pumpAndSettle();
    expect(find.text('撤销连接？'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('revoke-password')), 'pw');
    await tester.tap(find.text('立即撤销'));
    await tester.pumpAndSettle();
    expect(api.revoked, 'one');
  });
  testWidgets('连接页提供面向普通用户的教程入口', (tester) async {
    await pump(tester, FakeMcpGateway());
    expect(find.text('查看连接教程'), findsOneWidget);
  });
}
