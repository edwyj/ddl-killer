import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../app_version.dart';
import '../community_state.dart';

const feedbackStatuses = {
  'pending': '已收到',
  'confirmed': '问题已确认',
  'accepted': '建议已采纳',
  'resolved': '已解决',
  'duplicate': '已有相关反馈',
  'declined': '已回复',
};
const feedbackTypes = {'bug': '问题', 'suggestion': '建议', 'school': '课表适配'};

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});
  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await communityState.refreshFeedback();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '这次没能刷新，连接网络后可以再试一下。',
        );
      }
    }
  }

  Future<void> _create(String type) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FeedbackFormScreen(initialType: type)),
    );
    if (ok == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('问题与建议')),
    body: ListenableBuilder(
      listenable: communityState,
      builder: (context, _) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '一起，让 DDL Killer 更好用。',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              '哪里用着不顺手，或者有个想试试的新点子，都欢迎告诉我们。确认问题或采纳建议后，我们会送上一份 AI 体验奖励，感谢你的帮助。',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _create('bug'),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('写一条反馈'),
            ),
            TextButton.icon(
              onPressed: () => _create('school'),
              icon: const Icon(Icons.school_outlined),
              label: const Text('提交课表样本'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              '我的反馈',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (communityState.feedback.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('你提交的反馈和处理进展会显示在这里。'),
              ),
            for (final f in communityState.feedback)
              Card(
                child: ListTile(
                  title: Text(f['title'] as String),
                  subtitle: Text(
                    '${feedbackTypes[f['type']] ?? '反馈'} · ${feedbackStatuses[f['status']] ?? '已收到'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FeedbackDetailScreen(feedback: f),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class FeedbackFormScreen extends StatefulWidget {
  const FeedbackFormScreen({super.key, this.initialType = 'bug', this.submit});
  final String initialType;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? submit;
  @override
  State<FeedbackFormScreen> createState() => _FeedbackFormScreenState();
}

class _FeedbackFormScreenState extends State<FeedbackFormScreen> {
  final _title = TextEditingController(),
      _description = TextEditingController(),
      _school = TextEditingController();
  late String _type, _key;
  final _attachments = <Map<String, dynamic>>[];
  bool _busy = false, _sent = false, _restoring = true;
  String? _error;
  Timer? _draftTimer;
  int? _uid;
  bool _persist = false;
  String? get _draftKey => _uid == null
      ? null
      : 'community_feedback_draft_v1_${_uid}_${widget.initialType == 'school' ? 'school' : 'feedback'}';
  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _key = const Uuid().v4();
    _uid = Api.instance.offline.uid;
    _persist = Api.instance.offline.persistent;
    for (final c in [_title, _description, _school]) {
      c.addListener(_changed);
    }
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      if (_persist && _draftKey != null) {
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        final raw = prefs.getString(_draftKey!);
        if (raw != null) {
          try {
            final draft = jsonDecode(raw) as Map;
            _title.text = draft['title'] as String? ?? '';
            _description.text = draft['description'] as String? ?? '';
            _school.text = draft['school'] as String? ?? '';
            _key = draft['requestKey'] as String? ?? _key;
            if (widget.initialType != 'school' &&
                ['bug', 'suggestion'].contains(draft['type'])) {
              _type = draft['type'] as String;
            }
          } catch (_) {
            /* Ignore corrupted local draft. */
          }
        }
      }
    } catch (_) {
      // Storage may be unavailable; composing feedback must remain usable.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _changed() {
    if (_restoring || _sent) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_saveDraft()),
    );
  }

  Future<void> _saveDraft() async {
    if (!_persist ||
        _draftKey == null ||
        _sent ||
        Api.instance.offline.uid != _uid) {
      return;
    }
    final key = _draftKey!,
        value = jsonEncode({
          'title': _title.text,
          'description': _description.text,
          'school': _school.text,
          'requestKey': _key,
          'type': _type,
        });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_sent || Api.instance.offline.uid != _uid) return;
      await prefs.setString(key, value);
      if (_sent || Api.instance.offline.uid != _uid) await prefs.remove(key);
    } catch (_) {
      // Keep the current input usable when local storage is unavailable.
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    unawaited(_saveDraft());
    for (final c in [_title, _description, _school]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    if (_attachments.length >= 3) {
      setState(() => _error = '最多添加 3 个附件');
      return;
    }
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'png',
          'jpg',
          'jpeg',
          'pdf',
          'json',
          'html',
          'htm',
          'xls',
          'xlsx',
          'csv',
        ],
      );
      if (!mounted || result.isEmpty) return;
      final f = result.single;
      final size = f.lengthSync() ?? await f.length();
      if (!mounted) return;
      if (size > 2 * 1024 * 1024) {
        setState(() => _error = '文件不能超过 2 MB');
        return;
      }
      final bytes = await f.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) throw const FormatException();
      final total = _attachments.fold<int>(
        0,
        (sum, f) => sum + (f['size'] as int),
      );
      if (total + bytes.length > 2 * 1024 * 1024) {
        setState(() => _error = '附件合计不能超过 2 MB，可以先提交文字说明再补材料');
        return;
      }
      setState(() {
        _attachments.add({
          'name': f.name,
          'data': base64Encode(bytes),
          'size': bytes.length,
        });
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '这个文件暂时读不了，可以重新选择，或换一个文件试试。');
    }
  }

  Future<void> _submit() async {
    if (_busy || _restoring) return;
    FocusScope.of(context).unfocus();
    if (_type == 'school' && _school.text.trim().isEmpty) {
      setState(() => _error = '请填写学校名称');
      return;
    }
    if (_title.text.trim().isEmpty || _description.text.trim().isEmpty) {
      setState(() => _error = '请填写标题和说明');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final input = {
      'type': _type,
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'school': _school.text.trim(),
      'requestKey': _key,
      'platform': kIsWeb ? 'Web' : defaultTargetPlatform.name,
      'version': AppVersion.displayName,
      'attachments': _attachments
          .map((f) => {'name': f['name'], 'data': f['data']})
          .toList(),
    };
    try {
      await (widget.submit ??
          (body) => Api.instance.communityPost('/api/feedback', body))(input);
      _sent = true;
      _draftTimer?.cancel();
      if (_draftKey != null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_draftKey!);
        } catch (_) {
          /* Submission succeeded; never retry for a storage error. */
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('收到啦，谢谢你愿意告诉我们。后续回复和奖励可以在“消息”里查看。')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? e.message
              : '这次没能确认提交结果，文字和附件还在。可以稍后重试，也可以先去“我的反馈”看看是否已经收到。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_type == 'school' ? '提交课表样本' : '写反馈')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_restoring) const LinearProgressIndicator(),
                if (_type != 'school') ...[
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'bug',
                        label: Text('遇到问题'),
                        icon: Icon(Icons.bug_report_outlined),
                      ),
                      ButtonSegment(
                        value: 'suggestion',
                        label: Text('有个建议'),
                        icon: Icon(Icons.lightbulb_outline),
                      ),
                    ],
                    selected: {_type},
                    onSelectionChanged: _busy
                        ? null
                        : (s) {
                            setState(() => _type = s.first);
                            _changed();
                          },
                  ),
                  const SizedBox(height: 20),
                ] else ...[
                  const Text(
                    '目前支持的学校：山东大学、哈尔滨工业大学（深圳）',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '其他学校还在陆续接入。欢迎你提供课表样本，帮助我们更快支持你的学校。🎀\n\n不知道怎么导出也没关系，可以先告诉我们学校和教学平台，或发一张课表截图。',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _school,
                    enabled: !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: '学校 / 校区',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  key: const ValueKey('feedback-title'),
                  controller: _title,
                  enabled: !_busy,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: '一句话说说',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('feedback-description'),
                  controller: _description,
                  enabled: !_busy,
                  minLines: 5,
                  maxLines: 10,
                  maxLength: 5000,
                  decoration: InputDecoration(
                    labelText: _type == 'school' ? '教学平台与样本说明' : '详细说明',
                    hintText: _type == 'school'
                        ? '平台名称或网址、学期、第一周日期和节次时间。文件里缺的可以在这里补充。'
                        : _type == 'bug'
                        ? '当时做了什么？发生了什么？你期待的结果是什么？'
                        : '你希望怎样使用它？',
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (_type == 'school')
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      '优先提供平台导出的 Excel / PDF / JSON；也可以保存具体课表页面的 HTML 并附截图。请尽量提供完整学期，保留单双周、地点和节次信息。',
                    ),
                  ),
                for (final f in _attachments)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.attach_file),
                    title: Text(
                      f['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${((f['size'] as int) / 1024).ceil()} KB'),
                    trailing: IconButton(
                      tooltip: '移除附件',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _attachments.remove(f)),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('添加图片或文件'),
                ),
                const SizedBox(height: 10),
                Text(
                  '最多添加 3 个附件，合计不超过 2 MB。请先遮盖姓名、学号等个人信息，也不要上传密码或登录信息。\n\n附件用于处理反馈和完善课表导入；应用内的附件最多保留 60 天。离开编辑页后，附件需要重新选择。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextButton(
                  onPressed: () => openFeedbackPrivacy(context),
                  child: const Text('查看隐私说明'),
                ),
                const SizedBox(height: 12),
                Text(
                  '我们会附上应用版本（${AppVersion.displayName}），方便排查；不会自动读取你的任务或聊天。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy || _restoring ? null : _submit,
                  child: Text(_busy ? '正在提交…' : '提交反馈'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class FeedbackDetailScreen extends StatefulWidget {
  const FeedbackDetailScreen({super.key, required this.feedback});
  final Map<String, dynamic> feedback;
  @override
  State<FeedbackDetailScreen> createState() => _FeedbackDetailScreenState();
}

class _FeedbackDetailScreenState extends State<FeedbackDetailScreen> {
  late Map<String, dynamic> _feedback;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _feedback = widget.feedback;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final f = await Api.instance.communityGet(
        '/api/feedback/${_feedback['id']}',
      );
      if (mounted) {
        setState(() {
          _feedback = f;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '这次没能刷新，连接网络后可以再试一下。',
        );
      }
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await Api.instance.deleteFeedbackFiles(_feedback['id'] as int);
      await _load();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException ? e.message : '这次没能删除附件，请稍后再试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('反馈详情')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          _feedback['title'] as String,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(feedbackStatuses[_feedback['status']] ?? '已收到'),
        const SizedBox(height: 24),
        SelectableText(_feedback['description'] as String),
        if ((_feedback['reply'] as String? ?? '').isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text('回复', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          SelectableText(_feedback['reply'] as String),
        ],
        if ((_feedback['attachments'] as List? ?? []).isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text('已提交附件'),
          for (final f in _feedback['attachments'] as List)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(f['name'] as String),
            ),
          TextButton(
            onPressed: _busy ? null : _remove,
            child: const Text('删除应用内附件'),
          ),
        ],
        if ((_feedback['attachments'] as List? ?? []).isNotEmpty)
          const Text('这里会删除应用内保存的附件。如需我们一并删除处理反馈时保留的其他副本，请通过“问题与建议”告诉我们。'),
        TextButton(
          onPressed: () => openFeedbackPrivacy(context),
          child: const Text('查看隐私说明'),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}

Future<void> openFeedbackPrivacy(BuildContext context) async {
  try {
    if (await launchUrl(
      Uri.parse('https://ddlkiller.com/privacy.html'),
      mode: LaunchMode.externalApplication,
    )) {
      return;
    }
  } catch (_) {}
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('隐私说明暂时打不开，请稍后再试。')));
  }
}
