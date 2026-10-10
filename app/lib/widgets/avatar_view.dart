import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 渲染用户头像。支持后端约定的三种 avatar spec：
/// - `data:image/...;base64,...`  上传的照片
/// - `preset:<#hexcolor>:<字符>`  预设底色 + 单个字符/emoji
/// - 空串                         默认头像：用户名首字(大写) + 主题种子色
///
/// 该组件只负责“渲染”，不发起任何请求；解析工具同时供头像选择器复用。
class AvatarView extends StatefulWidget {
  const AvatarView({
    super.key,
    required this.avatar,
    this.username = '',
    this.size = 48,
  });

  /// avatar spec(来自 `Api.me().avatar`)，可为空串。
  final String avatar;

  /// 无头像时用于取首字；可为空(显示 '?')。
  final String username;

  final double size;

  /// 可选预设底色(选择器与渲染共用同一份，避免两处不一致)。
  static const List<String> presetColors = [
    '#7C4DFF', '#5C6BC0', '#29B6F6', '#26A69A', '#57B0A6', '#66BB6A',
    '#9CCC65', '#FFCA28', '#FFA726', '#FF7043', '#EF5350', '#EC407A',
  ];

  /// `#RRGGBB` / `#AARRGGBB`(可省略 `#`)均可；**不支持** 3 位简写。
  /// alpha 一律拉满：头像底色必须是实色，否则对比度判断(见 [onColor])会失真。
  static Color? parseHexColor(String hex) {
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v | 0xFF000000);
  }

  /// Color → `#RRGGBB`(与 [parseHexColor] 互逆，供调用方合成 preset spec)。
  static String hexOf(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 解析 `preset:<hex>:<char>`；不是合法预设时返回 null。
  /// 取第二个冒号之后的**全部**内容作为字符，故字符本身是冒号也能解析。
  static ({Color color, String hex, String char})? parsePreset(String spec) {
    if (!spec.startsWith('preset:')) return null;
    final rest = spec.substring('preset:'.length);
    final i = rest.indexOf(':');
    final hex = i >= 0 ? rest.substring(0, i) : rest;
    final char = i >= 0 ? rest.substring(i + 1) : '';
    final color = parseHexColor(hex);
    if (color == null) return null;
    return (color: color, hex: hex, char: char);
  }

  /// 解析 `data:image/...;base64,<payload>` → 原始字节；失败返回 null。
  static Uint8List? decodeDataUrl(String spec) {
    if (!spec.startsWith('data:image/')) return null;
    final i = spec.indexOf(',');
    if (i < 0) return null;
    try {
      return base64Decode(spec.substring(i + 1));
    } catch (_) {
      return null; // 坏数据不要炸整页，交给默认头像兜底
    }
  }

  /// 默认头像用的字符：用户名首字(大写)，取不到则 '?'。
  /// 用 runes 而非 [0]，避免 emoji 用户名被截成半个代理对。
  static String initialOf(String username) {
    if (username.isEmpty) return '?';
    try {
      return String.fromCharCode(username.runes.first).toUpperCase();
    } catch (_) {
      return '?';
    }
  }

  /// 底色上保证对比度的前景色。
  static Color onColor(Color bg) =>
      bg.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

  @override
  State<AvatarView> createState() => _AvatarViewState();
}

class _AvatarViewState extends State<AvatarView> {
  /// 解码后的照片字节，按 spec 缓存。
  /// data URL 动辄几十万字符：每次 build 重解码不仅费 CPU，还会因为
  /// MemoryImage 每次都是新实例(按 identity 比较)而让图片缓存**永远 miss**。
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = AvatarView.decodeDataUrl(widget.avatar);
  }

  @override
  void didUpdateWidget(AvatarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换 spec(改头像/退出重登)时立刻跟着变
    if (oldWidget.avatar != widget.avatar) {
      _bytes = AvatarView.decodeDataUrl(widget.avatar);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ClipOval(child: _content(context)),
    );
  }

  Widget _content(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // 图片解不出来(数据损坏)时退回默认头像，不要显示成错误图标
        errorBuilder: (ctx, err, stack) => _letterAvatar(ctx),
      );
    }
    final preset = AvatarView.parsePreset(widget.avatar);
    if (preset != null && preset.char.trim().isNotEmpty) {
      return _letterAvatar(context, bg: preset.color, text: preset.char.trim());
    }
    return _letterAvatar(context);
  }

  /// 默认头像：主题种子色 + 用户名首字。
  Widget _letterAvatar(BuildContext context, {Color? bg, String? text}) {
    final size = widget.size;
    final background = bg ?? seed;
    return Container(
      width: size,
      height: size,
      color: background,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: size * 0.12),
          child: Text(
            text ?? AvatarView.initialOf(widget.username),
            maxLines: 1,
            style: TextStyle(
              fontSize: size * 0.42,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: AvatarView.onColor(background),
            ),
          ),
        ),
      ),
    );
  }
}
