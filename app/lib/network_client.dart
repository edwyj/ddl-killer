import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic>? details;
  ApiException(this.message, {this.code, this.statusCode, this.details});
  @override
  String toString() => message;
}

class NetworkClient {
  NetworkClient({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 12),
  }) : clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() clientFactory;
  final Duration timeout;
  final warning = ValueNotifier<String?>(null);
  final Set<String> _stale = {};
  int _generation = 0;

  String? _account(String? token) {
    try {
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(token!.split('.')[1])),
        ),
      ) as Map;
      if ((payload['exp'] as num?) != null &&
          (payload['exp'] as num) * 1000 <=
              DateTime.now().millisecondsSinceEpoch) {
        return null;
      }
      return payload['uid']?.toString();
    } catch (_) {
      return null;
    }
  }

  void reset() {
    _generation++;
    _stale.clear();
    warning.value = null;
  }

  Future<void> clearCache() async {
    reset();
    final sp = await SharedPreferences.getInstance();
    for (final key in sp.getKeys().where(
      (k) => k.startsWith('read_cache_v1_'),
    )) {
      await sp.remove(key);
    }
  }

  Future<dynamic> request(
    String method,
    Uri uri,
    String? token, [
    Map? body,
    Duration? requestTimeout,
  ]) async {
    final uid = _account(token);
    final generation = _generation;
    final cacheable =
        !kIsWeb &&
        method == 'GET' &&
        uid != null &&
        !uri.path.startsWith('/api/auth') &&
        !uri.path.startsWith('/api/account') &&
        !uri.path.startsWith('/api/push') &&
        !uri.path.startsWith('/api/sync') &&
        !uri.path.startsWith('/api/ai') &&
        !uri.path.startsWith('/api/messages') &&
        !uri.path.startsWith('/api/feedback') &&
        !uri.path.startsWith('/api/referrals') &&
        !uri.path.startsWith('/api/rewards') &&
        uri.path != '/api/reminders';
    final prefix = 'read_cache_v1_${uri.host}_${uid}_';
    final key = '$prefix${uri.path}?${uri.query}';
    final attempts = method == 'GET' ? 2 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final client = clientFactory();
      try {
        final req = http.Request(
          method,
          uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              '_t': '${DateTime.now().millisecondsSinceEpoch}',
            },
          ),
        );
        if (token != null && !kIsWeb) {
          req.headers['Authorization'] = 'Bearer $token';
        }
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        final r = await (() async => http.Response.fromStream(
          await client.send(req),
        ))().timeout(requestTimeout ?? timeout);
        if (generation != _generation) throw ApiException('账号状态已改变，请重新加载');
        final emailEndpoint =
            uri.path == '/api/account/email' ||
            uri.path == '/api/account/email/code' ||
            uri.path.startsWith('/api/auth/email/');
        if (r.statusCode >= 500 &&
            !uri.path.startsWith('/api/ai/') &&
            !emailEndpoint) {
          throw const FormatException('Server unavailable');
        }
        dynamic data;
        try {
          data = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
        } catch (_) {
          if (r.statusCode >= 500 && emailEndpoint) rethrow;
          if (r.statusCode >= 400) {
            throw ApiException('请求失败（${r.statusCode}），请稍后重试');
          }
          rethrow;
        }
        if (r.statusCode >= 500 &&
            emailEndpoint &&
            !(data is Map &&
                data['error'] is String &&
                (data['error'] as String).isNotEmpty)) {
          throw const FormatException('Server unavailable');
        }
        if (r.statusCode < 200 || r.statusCode >= 300) {
          throw ApiException(
            (data is Map ? data['error']?.toString() : null) ??
                '请求失败（${r.statusCode}）',
            code: data is Map ? data['code']?.toString() : null,
            statusCode: r.statusCode,
            details: data is Map ? Map<String, dynamic>.from(data) : null,
          );
        }
        if (data == null) throw const FormatException('Empty response');
        try {
          if (cacheable || (method != 'GET' && uid != null)) {
            final sp = await SharedPreferences.getInstance();
            if (generation != _generation) throw ApiException('账号状态已改变，请重新加载');
            if (cacheable) {
              await sp.setString(
                key,
                jsonEncode({
                  'time': DateTime.now().millisecondsSinceEpoch,
                  'data': data,
                }),
              );
              if (generation != _generation) {
                await sp.remove(key);
                throw ApiException('账号状态已改变，请重新加载');
              }
              final entries = sp
                  .getKeys()
                  .where((k) => k.startsWith(prefix))
                  .toList();
              if (entries.length > 100) {
                for (final k in entries.take(entries.length - 100)) {
                  if (k != key) await sp.remove(k);
                }
              }
            } else if (method != 'GET') {
              for (final k in sp.getKeys().where((k) => k.startsWith(prefix))) {
                await sp.remove(k);
              }
            }
          }
        } catch (_) {
          /* Cache failures must not turn a successful save into a retry. */
        }
        _stale.remove(key);
        if (generation != _generation) throw ApiException('账号状态已改变，请重新加载');
        if (_stale.isEmpty) warning.value = null;
        return data;
      } on ApiException {
        rethrow;
      } catch (_) {
        if (generation != _generation) throw ApiException('账号状态已改变，请重新加载');
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
        if (cacheable) {
          try {
            final raw = (await SharedPreferences.getInstance()).getString(key);
            if (generation != _generation) throw ApiException('账号状态已改变，请重新加载');
            if (raw != null) {
              final cached = jsonDecode(raw) as Map;
              if (DateTime.now().millisecondsSinceEpoch -
                      (cached['time'] as int) <
                  const Duration(days: 7).inMilliseconds) {
                _stale.add(key);
                warning.value = '网络暂不可用，正在显示上次加载的内容';
                return cached['data'];
              }
            }
          } catch (_) {
            /* Unusable cache falls through to the network error. */
          }
        }
        throw ApiException(
          method == 'GET' ? '连接失败或超时，请检查网络后重试' : '未能确认保存结果，输入已保留。请刷新核对后再重试',
        );
      } finally {
        client.close();
      }
    }
  }
}
