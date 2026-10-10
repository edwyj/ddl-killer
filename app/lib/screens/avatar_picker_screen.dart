import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../widgets/avatar_view.dart';

/// 后端对 avatar 单字段的长度上限(超出会 400)。
const int kAvatarMaxLength = 500000;

/// 打开头像选择器。返回新的 avatar spec；用户取消返回 null；
/// 返回空串表示“恢复默认头像”(后端允许空串)。
Future<String?> pickAvatar(BuildContext context, {required String current}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true, // 键盘弹起时让内容整体上推
    showDragHandle: true,
    builder: (_) => _AvatarPickerSheet(current: current),
  );
}

class _AvatarPickerSheet extends StatefulWidget {
  const _AvatarPickerSheet({required this.current});

  final String current;

  @override
  State<_AvatarPickerSheet> createState() => _AvatarPickerSheetState();
}

class _AvatarPickerSheetState extends State<_AvatarPickerSheet> {
  late final TextEditingController _char;
  late String _colorHex;

  /// 已选照片的 data URL；非空时优先使用照片。
  String? _photo;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final preset = AvatarView.parsePreset(widget.current);
    _char = TextEditingController(text: preset?.char ?? '');
    _colorHex = preset?.hex ?? AvatarView.presetColors.first;
    // 当前就是照片时预览必须显示这张照片，否则会谎报成"默认头像"。
    // (parsePreset 对 data URL 返回 null，所以只能在这里单独认一次)
    _photo = widget.current.startsWith('data:image/') ? widget.current : null;
  }

  @override
  void dispose() {
    _char.dispose();
    super.dispose();
  }

  /// 只取 1 个**字素**：多码元 emoji(👍🏽 / 👨‍👩‍👧)不会被截成半个代理对。
  ///
  /// 这里是"单字符"约束的**唯一**落点（预览与保存都走它）：
  /// 没有用 `TextField.maxLength`，因为它在"字段已满 + 光标收起"时会直接
  /// 丢掉整次编辑（见 framework text_formatter.dart 的
  /// `if (oldValue...length == maxLength && selection.isCollapsed) return oldValue;`），
  /// 且 Android 默认 enforced 模式连 IME 组字中都会丢 → 预填了首字后中文根本打不进去。
  String get _normalizedChar {
    final t = _char.text.trim();
    return t.isEmpty ? '' : t.characters.first;
  }

  /// 聚焦即全选：字段通常预填着"当前首字"，用户来这里是要**换掉**它，
  /// 不全选的话新字会被追加成"A意"，而规范只取第一个字素 → 存下去还是 A。
  void _selectAll() {
    if (_char.text.isEmpty) return;
    _char.selection =
        TextSelection(baseOffset: 0, extentOffset: _char.text.length);
  }

  /// 当前预览用的 spec(字符为空时用 '?' 占位，提示还需输入)。
  String get _previewSpec {
    if (_photo != null) return _photo!;
    return 'preset:$_colorHex:${_normalizedChar.isEmpty ? '?' : _normalizedChar}';
  }

  /// 字符与照片都为空时不许保存(在 [_save] 里给出可见原因)。
  bool get _canSave => _photo != null || _normalizedChar.isNotEmpty;

  /// 500000 上限的统一守卫：照片与 preset 两条路径共用，
  /// 免得粘贴一个超长字符从客户端绕过、直接吃服务端 400。
  String? _tooLongError(String spec) => spec.length > kAvatarMaxLength
      ? '头像数据太大(${(spec.length / 1000).round()}k 字符，'
          '上限 ${kAvatarMaxLength ~/ 1000}k)，请换一张更小的图或更短的字符'
      : null;

  /// 从相册/相机取图 → bytes → base64。
  /// 注意：必须用 XFile.readAsBytes()，web 上没有 dart:io 的 File。
  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80, // 先压一道，尽量把 base64 控制在 500000 字符以内
      );
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final bytes = await picked.readAsBytes();
      final spec = 'data:${_sniffMime(bytes)};base64,${base64Encode(bytes)}';
      if (!mounted) return;
      final tooLong = _tooLongError(spec);
      if (tooLong != null) {
        setState(() {
          _busy = false;
          _photo = null; // 不要留着上一张旧图继续挂在预览与"待保存"状态上
          _error = tooLong;
        });
        return;
      }
      setState(() {
        _photo = spec;
        _busy = false;
      });
    } catch (e, st) {
      // 权限被拒 / 该平台不支持拍照 都会落到这里：给用户同一句话，
      // 但把原始错误打到日志，方便排查(浏览器上只有一条红色 console)。
      debugPrint('pickImage($source) 失败: $e\n$st');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '读取图片失败，请重试';
        });
      }
    }
  }

  /// 按文件头猜 mime(后端只要求 data:image/ 前缀，此处给出真实类型)。
  static String _sniffMime(Uint8List b) {
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && // RIFF
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  void _save() {
    final spec = _photo ?? 'preset:$_colorHex:$_normalizedChar';
    if (!_canSave) {
      setState(() => _error = '请输入 1 个字符或 emoji，或选择一张照片');
      return;
    }
    final tooLong = _tooLongError(spec);
    if (tooLong != null) {
      setState(() => _error = tooLong);
      return;
    }
    Navigator.of(context).pop(spec);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Text('选择头像', style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 14),
              Center(
                child: Stack(
                  children: [
                    AvatarView(avatar: _previewSpec, size: 88),
                    if (_busy)
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_photo != null) ...[
                const SizedBox(height: 6),
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _photo = null;
                              _error = null;
                            }),
                    child: const Text('改用字符头像'),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text('背景色', style: _labelStyle(theme)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: AvatarView.presetColors.map((hex) {
                  final color = AvatarView.parseHexColor(hex) ?? theme.colorScheme.primary;
                  final selected = _photo == null && hex == _colorHex;
                  return InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _busy
                        ? null
                        : () => setState(() {
                              _colorHex = hex;
                              _photo = null; // 选底色即回到字符头像
                              _error = null;
                            }),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: theme.colorScheme.onSurface, width: 3)
                            : null,
                      ),
                      child: selected
                          ? Icon(Icons.check, size: 20, color: AvatarView.onColor(color))
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              // Focus 只是为键盘聚焦也触发全选(外层 Focus 的 hasFocus 会被子节点点亮)
              Focus(
                onFocusChange: (hasFocus) {
                  if (hasFocus) _selectAll();
                },
                child: TextField(
                  controller: _char,
                  enabled: !_busy,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                  onTap: _selectAll,
                  decoration: const InputDecoration(
                    labelText: '字符',
                    hintText: '单个字或 emoji',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {
                    _photo = null; // 一改字符就回到字符头像，否则预览不会跟着动
                    _error = null;
                  }),
                ),
              ),
              if (!_canSave && _error == null) ...[
                const SizedBox(height: 8),
                Text(
                  '请输入 1 个字符或 emoji，或从相册选一张照片',
                  textAlign: TextAlign.center,
                  style: _labelStyle(theme),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('从相册选'),
                    ),
                  ),
                  // 相机在 web 上不受支持，直接不展示，避免点了抛异常
                  if (!kIsWeb) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: const Text('拍照'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  if (widget.current.isNotEmpty)
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(''),
                      child: const Text('恢复默认'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  // 始终可点：内容不合法时由 _save 给出可见原因，
                  // 而不是一个灰按钮 + 没解释(见上面的提示行)
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle? _labelStyle(ThemeData theme) => theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.outline,
        fontSize: 13,
      );
}
