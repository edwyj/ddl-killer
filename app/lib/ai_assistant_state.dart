import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models/ai_planner.dart';

typedef AiSettingsLoader = Future<AiAssistantSettings> Function();

class AiAssistantStateStore extends ChangeNotifier {
  AiAssistantStateStore(this._loader);

  final AiSettingsLoader _loader;
  AiAssistantSettings? settings;
  Future<AiAssistantSettings>? _inflight;
  int? _accountId;
  bool? _cachedFeatureEnabled;

  bool? get featureEnabled => settings?.featureEnabled ?? _cachedFeatureEnabled;

  Future<void> preload(int? accountId) async {
    if (_accountId == accountId) return;
    _accountId = accountId;
    settings = null;
    _inflight = null;
    if (accountId == null) {
      _cachedFeatureEnabled = null;
    } else {
      final storage = await SharedPreferences.getInstance();
      _cachedFeatureEnabled = storage.getBool(_enabledKey(accountId));
    }
    notifyListeners();
  }

  Future<AiAssistantSettings> load() async {
    final cached = settings;
    if (cached != null) {
      unawaited(refresh());
      return cached;
    }
    return refresh();
  }

  Future<AiAssistantSettings> refresh() {
    final pending = _inflight;
    if (pending != null) return pending;
    final accountAtStart = _accountId;
    final request = _loader().then((value) async {
      if (_accountId != accountAtStart) return value;
      final changed = !_sameSettings(settings, value);
      settings = value;
      _cachedFeatureEnabled = value.featureEnabled;
      final accountId = _accountId;
      if (accountId != null) {
        final storage = await SharedPreferences.getInstance();
        await Future.wait([
          storage.setBool(_enabledKey(accountId), value.featureEnabled),
          storage.setInt(
            _checkedKey(accountId),
            DateTime.now().millisecondsSinceEpoch,
          ),
        ]);
      }
      if (changed) notifyListeners();
      return value;
    });
    _inflight = request;
    request.then(
      (_) {
        if (identical(_inflight, request)) _inflight = null;
      },
      onError: (_) {
        if (identical(_inflight, request)) _inflight = null;
      },
    );
    return request;
  }

  void clear() {
    settings = null;
    _inflight = null;
    _accountId = null;
    _cachedFeatureEnabled = null;
    notifyListeners();
  }

  Future<AiAssistantSettings> refreshAfterMutation() async {
    final pending = _inflight;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        /* Fetch fresh state below. */
      }
    }
    return refresh();
  }

  static String _enabledKey(int uid) => 'ai_feature_enabled_v1_$uid';
  static String _checkedKey(int uid) => 'ai_feature_checked_at_v1_$uid';
}

bool _sameSettings(AiAssistantSettings? left, AiAssistantSettings right) {
  if (left == null) return false;
  return left.mode == right.mode &&
      left.featureEnabled == right.featureEnabled &&
      left.provider?.provider == right.provider?.provider &&
      left.provider?.baseUrl == right.provider?.baseUrl &&
      left.provider?.model == right.provider?.model &&
      left.provider?.keyMask == right.provider?.keyMask &&
      left.quota.limit == right.quota.limit &&
      left.quota.used == right.quota.used &&
      left.quota.reserved == right.quota.reserved &&
      left.quota.remaining == right.quota.remaining &&
      left.quota.hostedEnabled == right.quota.hostedEnabled &&
      listEquals(
        left.quota.entitlements.map((e) => '${e.id}:${e.expiresAt}').toList(),
        right.quota.entitlements.map((e) => '${e.id}:${e.expiresAt}').toList(),
      ) &&
      left.quota.copy == right.quota.copy;
}

final aiAssistantState = AiAssistantStateStore(() => Api.instance.aiSettings());
