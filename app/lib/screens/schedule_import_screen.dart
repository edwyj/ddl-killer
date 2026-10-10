import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';

import 'dart:convert';

import '../api.dart';
import '../build_channel.dart';
import 'feedback_screen.dart';

/// 「如何获得课表」图文教程。页面在 app/web/kebiao-help.html，配图 app/web/kbimg/，
/// 配套油猴脚本 app/web/userscript/sdu-kebiao-export.user.js —— 三者都随
/// `flutter build web` 一起发布到 main-server 的 ~/plan/web/ 下。
const kHowToGetScheduleUrl = BuildChannel.beta
    ? 'https://beta.ddlkiller.com/kebiao-help.html'
    : 'https://ddlkiller.com/kebiao-help.html';

class ScheduleImportScreen extends StatefulWidget {
  const ScheduleImportScreen({super.key, this.pickFile, this.importSchedule});
  final Future<PlatformFile?> Function()? pickFile;
  final Future<void> Function(Map<String, dynamic>)? importSchedule;
  @override
  State<ScheduleImportScreen> createState() => _ScheduleImportScreenState();
}

class _ScheduleImportScreenState extends State<ScheduleImportScreen> {
  final _json = TextEditingController();
  final _jsonFocus = FocusNode();
  bool _busy = false;
  bool _picking = false;
  String? _fileName;
  String? _error;

  /// 浏览器里有没有文件正拖在窗口上方 —— 用来铺那层「松手导入」。
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _jsonFocus.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {});

  @override
  void dispose() {
    _jsonFocus.removeListener(_focusChanged);
    _jsonFocus.dispose();
    _json.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(_json.text) as Map<String, dynamic>;
      _checkSchedule(obj);
    } catch (_) {
      setState(() => _error = '课表内容无法识别，请选择导出的 JSON 文件，或检查粘贴的内容是否完整。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.importSchedule ?? Api.instance.importSchedule)(obj);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '无法连接服务器';
      });
    }
  }

  void _checkSchedule(Map<String, dynamic> value) {
    final courses = value['courses'];
    final semester = value['semester_start'];
    if ((semester == null && courses is! List) ||
        (courses != null &&
            (courses is! List || courses.any((course) => course is! Map))) ||
        (semester != null &&
            (semester is! String ||
                !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(semester) ||
                DateTime.tryParse(semester) == null))) {
      throw const FormatException('课表内容无法识别，请选择导出的课表 JSON 文件。');
    }
  }

  Future<void> _pickFile() async {
    if (_busy || _picking) return;
    setState(() => _picking = true);
    try {
      final file =
          await (widget.pickFile?.call() ??
              FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: const ['json'],
              ));
      if (!mounted || file == null) return;
      if (!file.name.toLowerCase().endsWith('.json')) {
        throw const FormatException('请选择 JSON 格式的课表文件。');
      }
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('课表文件超过 1 MB，请确认选择的是导出的课表。');
      }
      final bytes = <int>[];
      await for (final chunk in file.readAsByteStream()) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('课表文件超过 1 MB，请确认选择的是导出的课表。');
        }
      }
      final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('课表内容无法识别，请选择导出的 JSON 文件。');
      }
      _checkSchedule(value);
      if (!mounted) return;
      setState(() {
        _json.text = text;
        _fileName = file.name;
        _error = null;
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '暂时无法打开文件，请重新选择，或粘贴课表内容。');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 把拖进来的 schedule.json 读成文本填进输入框，然后直接当作点了「保存」。
  /// 出错时内容留在输入框里，用户能自己看一眼是哪儿不对。
  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    if (_busy || _picking) return;
    final json = d.files.where((f) => f.name.toLowerCase().endsWith('.json'));
    if (json.isEmpty) {
      setState(
        () => _error = d.files.isEmpty
            ? '没读到文件，直接把 schedule.json 拖进来试试'
            : '拖进来的不是 json 文件（${d.files.first.name}）',
      );
      return;
    }
    String text;
    try {
      if (await json.first.length() > 1024 * 1024) {
        if (mounted) setState(() => _error = '课表文件超过 1 MB，请确认选择的是导出的课表。');
        return;
      }
      text = await json.first.readAsString();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '这个文件读不出来，重新从浏览器下载一次再试');
      return;
    }
    if (!mounted) return;
    _json.text = text;
    await _save();
  }

  /// 打开「如何获得课表」教程。桌面/无浏览器时 launchUrl 会返回 false 或抛异常，都要兜住。
  Future<void> _openHelp() async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(kHowToGetScheduleUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法打开教程，请手动访问 ddlkiller.com/kebiao-help.html'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // DropTarget 包住整个窗口（不是只包输入框）——同学多半会把文件往页面中间丢。
    return DropTarget(
      onDragEntered: (_) {
        if (!_dragging) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (_dragging) setState(() => _dragging = false);
      },
      onDragDone: _onDrop,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Scaffold(
            appBar: AppBar(title: const Text('导入课表')),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '目前支持的学校：山东大学、哈尔滨工业大学（深圳）',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const FeedbackFormScreen(initialType: 'school'),
                        ),
                      ),
                      icon: const Icon(Icons.school_outlined, size: 18),
                      label: const Text('还没有你的学校？提交课表样本'),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _busy || _picking ? null : _pickFile,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(_picking ? '正在打开文件…' : '选择课表文件'),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _fileName == null
                          ? '选择导出的 JSON 文件，确认内容后点“导入课表”。也可以直接粘贴内容。'
                          : '已选择：$_fileName。确认后点“导入课表”。',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (kIsWeb) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.file_download_outlined,
                          size: 18,
                          color: cs.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '电脑网页版也支持拖入课表文件。',
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _json,
                      focusNode: _jsonFocus,
                      textAlignVertical: TextAlignVertical.top,
                      readOnly: _busy || _picking,
                      maxLines: null,
                      expands: true,
                      decoration: InputDecoration(
                        hintText: _jsonFocus.hasFocus ? null : '粘贴课表 JSON 内容',
                        hintMaxLines: 1,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy || _picking ? null : _save,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _busy
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : const Text('导入课表'),
                  ),
                  TextButton.icon(
                    onPressed: _openHelp,
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('如何获得课表'),
                  ),
                ],
              ),
            ),
          ),
          // 拖动中：整页淡蓝 + 中间一张「松手导入」卡片。IgnorePointer 让指针事件穿过去，
          // 落点判定仍然是 DropTarget 那一层在算。
          if (_dragging)
            IgnorePointer(
              child: Container(
                color: cs.primary.withValues(alpha: 0.10),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cs.primary, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.file_download_outlined,
                          size: 34,
                          color: cs.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '松手导入课表',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
