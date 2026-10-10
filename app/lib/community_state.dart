import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

typedef CommunityLoader = Future<Map<String, dynamic>> Function(String path);

class CommunityState extends ChangeNotifier {
  CommunityState({required this.loader});
  final CommunityLoader loader;
  int? _uid;
  bool _persistent = false;
  int _epoch = 0;
  Future<void>? _messagesFlight;
  List<Map<String, dynamic>> messages = [];
  List<Map<String, dynamic>> feedback = [];
  Map<String, dynamic>? referral;
  Map<String, dynamic>? planningPreferences;
  int unread = 0;
  String? messageError;
  bool messagesLoaded = false;
  bool hasMoreMessages = false;
  bool loadingMoreMessages = false;

  Future<void> attach(int? uid, {required bool persistent}) async {
    if (uid == _uid && persistent == _persistent) return;
    clear();
    _uid = uid;
    _persistent = persistent;
    if (uid == null || !persistent) return;
    final epoch = _epoch;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('community_messages_v1_$uid');
    if (epoch != _epoch) return;
    if (raw != null) {
      try {
        _acceptMessages(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      } catch (_) {
        /* Ignore corrupted display cache. */
      }
    }
    notifyListeners();
  }

  void clear() {
    _epoch++;
    _uid = null;
    _persistent = false;
    _messagesFlight = null;
    messages = [];
    feedback = [];
    referral = null;
    planningPreferences = null;
    unread = 0;
    messageError = null;
    messagesLoaded = false;
    hasMoreMessages = false;
    loadingMoreMessages = false;
    notifyListeners();
  }

  void _acceptMessages(Map<String, dynamic> data) {
    final byId = <int, Map<String, dynamic>>{};
    for (final value in data['items'] as List? ?? []) {
      final item = Map<String, dynamic>.from(value as Map);
      byId.putIfAbsent(item['id'] as int, () => item);
    }
    messages = byId.values.toList()
      ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    unread = data['unread'] as int? ?? 0;
    messagesLoaded = true;
    hasMoreMessages = data['hasMore'] == true;
  }

  Future<void> refreshMessages() {
    final pending = _messagesFlight;
    if (pending != null) return pending;
    final epoch = _epoch, uid = _uid;
    if (uid == null) return Future.value();
    final flight = () async {
      try {
        final data = await loader('/api/messages');
        if (epoch != _epoch) return;
        final incoming = (data['items'] as List? ?? []).cast<Map>();
        final oldest = incoming.isEmpty ? null : incoming.last['id'] as int;
        final cachedIds = messages.map((m) => m['id']).toSet();
        final overlaps = incoming.any((m) => cachedIds.contains(m['id']));
        final older = oldest == null || !overlaps
            ? <Map<String, dynamic>>[]
            : messages.where((m) => (m['id'] as int) < oldest).toList();
        _acceptMessages({
          ...data,
          'items': [...incoming, ...older],
          'hasMore': older.isNotEmpty ? hasMoreMessages : data['hasMore'],
        });
        messageError = null;
        notifyListeners();
        if (_persistent) {
          final preferences = await SharedPreferences.getInstance();
          if (epoch != _epoch) return;
          final key = 'community_messages_v1_$uid';
          await preferences.setString(
            key,
            jsonEncode({
              'items': messages,
              'unread': unread,
              'hasMore': hasMoreMessages,
            }),
          );
          if (epoch != _epoch) await preferences.remove(key);
        }
      } catch (error) {
        if (epoch == _epoch) {
          messageError = error is ApiException
              ? error.message
              : '消息暂时无法刷新，已保存的消息仍可查看';
          notifyListeners();
        }
      }
    }();
    _messagesFlight = flight;
    flight.whenComplete(() {
      if (identical(_messagesFlight, flight)) _messagesFlight = null;
    });
    return flight;
  }

  Future<void> refreshFeedback() async {
    final epoch = _epoch;
    final data = await loader('/api/feedback');
    if (epoch != _epoch) return;
    feedback = (data['items'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    notifyListeners();
  }

  Future<void> refreshMessagesAfterMutation() async {
    final pending = _messagesFlight;
    if (pending != null) await pending;
    await refreshMessages();
  }

  Future<void> loadMoreMessages() async {
    if (loadingMoreMessages || !hasMoreMessages || messages.isEmpty) return;
    final epoch = _epoch;
    loadingMoreMessages = true;
    notifyListeners();
    try {
      final data = await loader('/api/messages?before=${messages.last['id']}');
      if (epoch != _epoch) return;
      _acceptMessages({
        ...data,
        'items': [...messages, ...(data['items'] as List)],
      });
      messageError = null;
      if (_persistent) {
        final uid = _uid;
        final storage = await SharedPreferences.getInstance();
        if (epoch == _epoch) {
          final key = 'community_messages_v1_$uid';
          await storage.setString(
            key,
            jsonEncode({
              'items': messages,
              'unread': unread,
              'hasMore': hasMoreMessages,
            }),
          );
          if (epoch != _epoch) await storage.remove(key);
        }
      }
    } catch (e) {
      if (epoch == _epoch) {
        messageError = e is ApiException ? e.message : '暂时无法加载更早的消息，联网后再试';
      }
    } finally {
      if (epoch == _epoch) {
        loadingMoreMessages = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshReferral() async {
    final epoch = _epoch;
    final data = await loader('/api/referrals');
    if (epoch != _epoch) return;
    referral = data;
    notifyListeners();
  }

  void markRead(int id) {
    for (final m in messages) {
      if (m['id'] == id && m['read'] != true) {
        m['read'] = true;
        unread = (unread - 1).clamp(0, 1000000);
        notifyListeners();
        break;
      }
    }
  }
}

final communityState = CommunityState(loader: Api.instance.communityGet);
