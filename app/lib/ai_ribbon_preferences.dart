import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AiRibbonSide { left, right }

class AiRibbonPreferences extends ChangeNotifier {
  AiRibbonPreferences._({
    required this._storage,
    required this.enabled,
    required this.emoji,
    required this.side,
    required this.yFraction,
  });

  static const _enabledKey = 'ai_ribbon_enabled_v1';
  static const _emojiKey = 'ai_ribbon_emoji_v1';
  static const _sideKey = 'ai_ribbon_side_v1';
  static const _yKey = 'ai_ribbon_y_v1';
  static Future<AiRibbonPreferences>? _shared;
  static AiRibbonPreferences? _current;

  final SharedPreferences _storage;
  bool enabled;
  String emoji;
  AiRibbonSide side;
  double yFraction;

  static Future<AiRibbonPreferences> load() async {
    final storage = await SharedPreferences.getInstance();
    final candidate = storage.getString(_emojiKey) ?? '🎀';
    return _current = AiRibbonPreferences._(
      storage: storage,
      enabled: storage.getBool(_enabledKey) ?? true,
      emoji: isSingleEmoji(candidate) ? candidate : '🎀',
      side: storage.getString(_sideKey) == 'left'
          ? AiRibbonSide.left
          : AiRibbonSide.right,
      yFraction: (storage.getDouble(_yKey) ?? 0.55).clamp(0, 1),
    );
  }

  static Future<AiRibbonPreferences> shared() => _shared ??= load();
  static AiRibbonPreferences? get current => _current;

  static bool isSingleEmoji(String value) {
    if (value.characters.length != 1) return false;
    return value.runes.any(
      (rune) =>
          rune == 0xfe0f ||
          rune == 0x2b50 ||
          (rune >= 0x1f000 && rune <= 0x1faff) ||
          (rune >= 0x2600 && rune <= 0x27bf),
    );
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    notifyListeners();
    await _storage.setBool(_enabledKey, value);
  }

  Future<bool> setEmoji(String value) async {
    if (!isSingleEmoji(value)) return false;
    emoji = value;
    notifyListeners();
    await _storage.setString(_emojiKey, value);
    return true;
  }

  Future<void> setPosition(AiRibbonSide value, double fraction) async {
    side = value;
    yFraction = fraction.clamp(0, 1);
    notifyListeners();
    await Future.wait([
      _storage.setString(_sideKey, side.name),
      _storage.setDouble(_yKey, yFraction),
    ]);
  }
}
