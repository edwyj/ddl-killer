class McpConnection {
  final String id, name, clientType;
  final List<String> scopes;
  final DateTime expiresAt, createdAt;
  final DateTime? lastUsedAt, revokedAt;
  const McpConnection({
    required this.id,
    required this.name,
    required this.clientType,
    required this.scopes,
    required this.expiresAt,
    required this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
  });
  factory McpConnection.fromJson(Map<String, dynamic> json) => McpConnection(
    id: json['id'] as String,
    name: json['name'] as String,
    clientType: json['clientType'] as String,
    scopes: List<String>.from(json['scopes'] as List),
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastUsedAt: json['lastUsedAt'] == null
        ? null
        : DateTime.parse(json['lastUsedAt'] as String),
    revokedAt: json['revokedAt'] == null
        ? null
        : DateTime.parse(json['revokedAt'] as String),
  );
}

class CreatedMcpToken {
  final String token;
  final McpConnection client;
  const CreatedMcpToken({required this.token, required this.client});
}

class McpAuditEntry {
  final String clientName, toolName, resultCode;
  final DateTime createdAt;
  const McpAuditEntry({
    required this.clientName,
    required this.toolName,
    required this.resultCode,
    required this.createdAt,
  });
  factory McpAuditEntry.fromJson(Map<String, dynamic> json) => McpAuditEntry(
    clientName: json['clientName'] as String,
    toolName: json['toolName'] as String,
    resultCode: json['resultCode'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}
