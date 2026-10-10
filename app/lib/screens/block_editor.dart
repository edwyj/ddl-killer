import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';

const List<String> _palette = [
  '#5C8DEF', '#E891A8', '#9B7EDE', '#E4C56B',
  '#6BB5A0', '#E89A6B', '#C48EDE', '#6BB5C9',
];

class BlockEditor extends StatefulWidget {
  final String date;
  final TimelineItem? item;
  final int? startMin;
  final int? endMin;

  const BlockEditor({super.key, required this.date, this.item, this.startMin, this.endMin});

  @override
  State<BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends State<BlockEditor> {
  late final TextEditingController _title;
  late final TextEditingController _note;
  late int _startMin;
  late int _endMin;
  late String _color;
  late bool _done;
  bool _saving = false;
  bool get _isNew => widget.item == null;

  @override
  void initState() {
    super.initState();
    // 旧标题里的结尾括号(如"午饭(16点...)")自动拆成 标题 + 备注，避免时间轴上过长
    final (cleanTitle, parenNote) = splitTitleNote(widget.item?.title ?? '');
    _title = TextEditingController(text: cleanTitle);
    _note = TextEditingController(text: widget.item?.note ?? parenNote ?? '');
    _startMin = widget.item?.startMin ?? widget.startMin ?? 540;
    _endMin = widget.item?.endMin ?? widget.endMin ?? 600;
    _color = widget.item?.color ?? '#8E7CC3';
    _done = widget.item?.done ?? false;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickTime(bool isStart) async {
    final cur = isStart ? _startMin : _endMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
    );
    if (picked != null) {
      setState(() {
        final v = picked.hour * 60 + picked.minute;
        if (isStart) {
          _startMin = v;
          if (_endMin <= v) _endMin = (v + 60).clamp(1, 1440);
        } else {
          _endMin = v > _startMin ? v : _startMin + 60;
        }
      });
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('填个标题吧')));
      return;
    }
    final note = _note.text.trim();
    setState(() => _saving = true);
    try {
      if (_isNew) {
        await Api.instance.addBlock(widget.date, _startMin, _endMin, title,
            color: _color, note: note);
      } else {
        await Api.instance.updateBlock(widget.item!.id!,
            startMin: _startMin, endMin: _endMin, title: title, color: _color, done: _done, note: note);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _delete() async {
    if (_isNew || widget.item!.id == null) return;
    setState(() => _saving = true);
    try {
      await Api.instance.deleteBlock(widget.item!.id!);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  String _fmt(int min) {
    final h = (min ~/ 60).toString().padLeft(2, '0');
    final m = (min % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新安排' : '编辑安排'),
        actions: [
          if (!_isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '标题',
              hintText: '做什么?',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: '备注(可选)',
              hintText: '补充说明，如"16点生伦下课到19点武术前"',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _timeButton('开始', _startMin, () => _pickTime(true))),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.arrow_forward, size: 18),
              ),
              Expanded(child: _timeButton('结束', _endMin, () => _pickTime(false))),
            ],
          ),
          const SizedBox(height: 20),
          Text('颜色', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _hexColor(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (!_isNew) ...[
            const SizedBox(height: 20),
            SwitchListTile(
              value: _done,
              onChanged: (v) => setState(() => _done = v),
              title: const Text('已完成'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(_isNew ? '保存' : '保存修改'),
          ),
        ],
      ),
    );
  }

  Widget _timeButton(String label, int min, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
          Text(_fmt(min), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

Color _hexColor(String hex) {
  var s = hex.replaceFirst('#', '');
  if (s.length == 6) s = 'FF$s';
  return Color(int.parse(s, radix: 16));
}
