import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'build_channel.dart';

typedef InstalledVersion = ({String name, int build});

class AppRelease {
  AppRelease({
    required this.version,
    required this.build,
    required this.url,
    required this.notes,
    this.webRevision = '',
  });
  final String version, notes;
  final String webRevision;
  final int build;
  final Uri url;
  Uri get downloadUrl => BuildChannel.beta ? BuildChannel.downloadPage : url;
  factory AppRelease.parse(Map<String, dynamic> json) {
    final version = json['version'], build = json['build_number'];
    final uri = Uri.tryParse(json['apk_url']?.toString() ?? '');
    if (version is! String ||
        !(BuildChannel.beta
                ? RegExp(r'^[0-9]+[.][0-9]+[.][0-9]+-beta\.[0-9]+$')
                : RegExp(r'^[0-9]+[.][0-9]+[.][0-9]+$'))
            .hasMatch(version) ||
        build is! int ||
        build < 1 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host !=
            (BuildChannel.beta ? 'beta.ddlkiller.com' : 'ddlkiller.com') ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.path !=
            (BuildChannel.beta
                ? '/'
                : '/releases/ddl-killer-$version-$build.apk') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('无效的更新信息');
    }
    return AppRelease(
      version: version,
      build: build,
      url: uri,
      notes: json['notes'] is String ? json['notes'] as String : '',
      webRevision:
          json['web_revision'] is String &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(json['web_revision'] as String)
          ? json['web_revision'] as String
          : '',
    );
  }
}

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    http.Client? client,
    Future<InstalledVersion> Function()? installed,
    DateTime Function()? now,
    Uri? manifestOrigin,
    @visibleForTesting bool? web,
    @visibleForTesting String? installedWebRevision,
  }) : _client = client ?? http.Client(),
       _readInstalled = installed ?? _packageVersion,
       _now = now ?? DateTime.now,
       _web = web ?? kIsWeb,
       _installedWebRevision = installedWebRevision ?? BuildChannel.webRevision,
       _origins = manifestOrigin != null
           ? [manifestOrigin]
           : BuildChannel.beta
           ? [Uri.parse(BuildChannel.origin)]
           : kIsWeb
           ? [Uri.base]
           : [Uri.https('ddlkiller.com'), Uri.https('app.ddlkiller.com')];
  static final instance = AppUpdates();
  final http.Client _client;
  final Future<InstalledVersion> Function() _readInstalled;
  final DateTime Function() _now;
  final List<Uri> _origins;
  final bool _web;
  final String _installedWebRevision;
  String diagnostic = '';
  InstalledVersion installed = (
    name: AppVersion.displayName,
    build: AppVersion.build,
  );
  AppRelease? release;
  String? error;
  Object? lastError;
  bool checking = false, checked = false;
  DateTime? _lastAttempt;
  Future<void>? _flight;
  int? promptedBuild;
  String? promptedRevision;
  bool get isWeb => _web;
  static Future<InstalledVersion> _packageVersion() async {
    return (name: AppVersion.displayName, build: AppVersion.build);
  }

  bool get available =>
      release != null &&
      (release!.build > installed.build ||
          (_web &&
              _installedWebRevision.isNotEmpty &&
              release!.webRevision.isNotEmpty &&
              release!.webRevision != _installedWebRevision &&
              release!.build >= installed.build));
  String get status => checking
      ? '正在检查更新'
      : available
      ? '发现新版本 ${release!.version}'
      : error != null
      ? '暂时无法检查更新'
      : checked && BuildChannel.beta
      ? '已经是最新测试版'
      : checked
      ? '已经是最新版本'
      : '检查更新';
  Future<void> check({bool force = false, Duration? minimumInterval}) {
    if (_flight != null) return _flight!;
    if (!force &&
        _lastAttempt != null &&
        _now().difference(_lastAttempt!) <
            (minimumInterval ?? Duration(minutes: error == null ? 360 : 5))) {
      return Future.value();
    }
    return _flight = _check().whenComplete(() => _flight = null);
  }

  Future<void> _check() async {
    checking = true;
    error = null;
    lastError = null;
    _lastAttempt = _now();
    notifyListeners();
    try {
      installed = await _readInstalled().timeout(const Duration(seconds: 5));
      diagnostic = '';
      AppRelease? fetched;
      Object? lastFailure;
      for (final origin in _origins) {
        final uri = origin.replace(
          path: '/app-update.json',
          queryParameters: {'t': '${_now().millisecondsSinceEpoch}'},
          fragment: '',
        );
        try {
          final response = await _client
              .get(uri)
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) {
            throw _UpdateHttpFailure(response.statusCode);
          }
          fetched = AppRelease.parse(
            Map<String, dynamic>.from(
              jsonDecode(utf8.decode(response.bodyBytes)) as Map,
            ),
          );
          break;
        } catch (failure) {
          lastFailure = failure;
          final detail = failure is _UpdateHttpFailure
              ? 'HTTP ${failure.status}'
              : failure is TimeoutException
              ? 'timeout'
              : failure is FormatException || failure is TypeError
              ? 'invalid manifest'
              : failure is http.ClientException
              ? 'network/TLS failure'
              : failure.runtimeType.toString();
          diagnostic += '${origin.host}: $detail\n';
        }
      }
      if (fetched == null) throw lastFailure ?? const FormatException('更新信息为空');
      release = fetched;
      checked = true;
    } catch (failure) {
      lastError = failure;
      error = failure is TimeoutException
          ? '检查更新超时，请稍后重试'
          : failure is FormatException || failure is TypeError
          ? '更新信息暂时不可用，请稍后重试'
          : failure is _UpdateHttpFailure
          ? '更新服务暂时不可用，请稍后重试'
          : '无法连接更新服务，请检查网络或从官网下载';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<bool> shouldPrompt() async {
    if (!available ||
        (promptedBuild == release!.build &&
            (!_web || promptedRevision == release!.webRevision))) {
      return false;
    }
    final until =
        (await SharedPreferences.getInstance()).getInt(
          _snoozeKey(release!.build),
        ) ??
        0;
    return _now().millisecondsSinceEpoch >= until;
  }

  String _snoozeKey(int build) =>
      'update_snooze_$build'
      '${_web && release?.build == build && release!.webRevision.isNotEmpty ? '_${release!.webRevision}' : ''}';

  Future<void> defer(int build) async {
    await (await SharedPreferences.getInstance()).setInt(
      _snoozeKey(build),
      _now().add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

class _UpdateHttpFailure implements Exception {
  const _UpdateHttpFailure(this.status);
  final int status;
}
