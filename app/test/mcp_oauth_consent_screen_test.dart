import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_app/screens/mcp_oauth_consent_screen.dart';

class FakeOAuthGateway implements McpOAuthGateway {
  String? approved;
  @override
  Future<McpOAuthRequest> request(String requestId) async => McpOAuthRequest(
    requestId: requestId,
    clientName: 'Claude Code',
    scopes: const ['mcp:read', 'mcp:schedule:draft'],
  );
  @override
  Future<Uri> approve(String requestId, List<String> scopes) async {
    approved = requestId;
    return Uri.parse('https://client.example/callback?code=safe');
  }

  @override
  Future<Uri> deny(String requestId) async =>
      Uri.parse('https://client.example/callback?error=access_denied');
}

void main() {
  testWidgets('同意页只使用服务端校验的请求与回调', (tester) async {
    final api = FakeOAuthGateway();
    Uri? redirected;
    await tester.pumpWidget(
      MaterialApp(
        home: McpOAuthConsentScreen(
          requestId: 'server-request-1',
          gateway: api,
          onRedirect: (uri) {
            redirected = uri;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.textContaining('查看你的清单'), findsOneWidget);
    await tester.tap(find.text('允许连接'));
    await tester.pumpAndSettle();
    expect(api.approved, 'server-request-1');
    expect(redirected.toString(), 'https://client.example/callback?code=safe');
  });
}
