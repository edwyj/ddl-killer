import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'dart:convert';

class AuthStore {
  static const _kToken = 'auth_token';
  static const _secure = FlutterSecureStorage();

  static Future<String?> loadToken({int? cachedUid}) async {
    final sp = await SharedPreferences.getInstance();
    // The old plaintext credentials are intentionally not migrated: legacy
    // server sessions have been invalidated by the security release.
    await sp.remove(_kToken);
    if (kIsWeb) {
      if (cachedUid != null) return 'web:$cachedUid';
      for (final k in sp.getKeys().where(
        (k) => k.startsWith('read_cache_v1_'),
      )) {
        await sp.remove(k);
      }
      const override = String.fromEnvironment('API_BASE');
      final base = override.isEmpty ? Uri.base.origin : override;
      final r = await http
          .get(Uri.parse('$base/api/auth/session'))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 401) return null;
      if (r.statusCode != 200) throw StateError('无法验证登录状态');
      return 'web:${(jsonDecode(r.body) as Map)['uid']}';
    }
    return _secure.read(key: _kToken);
  }

  static Future<void> saveToken(String t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kToken);
    if (!kIsWeb) await _secure.write(key: _kToken, value: t);
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kToken);
    if (!kIsWeb) await _secure.delete(key: _kToken);
    for (final k in sp.getKeys().where(
      (k) =>
          k.startsWith('read_cache_v1_') ||
          k.startsWith('community_messages_v1_') ||
          k.startsWith('community_feedback_draft_v1_'),
    )) {
      await sp.remove(k);
    }
  }
}
