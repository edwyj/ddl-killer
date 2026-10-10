import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api.dart';
import '../auth_store.dart';
import '../models.dart';
import '../widgets/course_details_sheet.dart';
import '../widgets/timeline_view.dart';
import 'block_editor.dart';
import 'inbox_screen.dart';
import 'login_screen.dart';

class DayScreen extends StatefulWidget {
  const DayScreen({super.key});

  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  DateTime _date = DateTime.now();
  final DateTime _today = DateTime.now();
  List<TimelineItem> _items = [];
  bool _loading = true;
  String? _error;
  int? _week;

  String get _dateStr => DateFormat('yyyy-MM-dd').format(_date);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await Api.instance.day(_dateStr);
      if (!mounted) return;
      final classWeek = items.where((i) => i.type == 'class').map((i) => i.weekNum).whereType<int>().toList();
      setState(() {
        _items = items;
        _week = classWeek.isNotEmpty ? classWeek.first : null;
        _loading = false;
      });
    } on ApiException catch (e) {
      // ignore: avoid_print
      print('DAY_API_ERROR: ${e.message}');
      if (e.message.contains('登录')) {
        await AuthStore.clear();
        Api.instance.token = null;
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
            (_) => false,
          );
        }
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('DAY_NET_ERROR: $e');
      setState(() {
        _error = '网络错误: $e';
        _loading = false;
      });
    }
  }

  void _shift(int days) {
    setState(() => _date = _date.add(Duration(days: days)));
    _load();
  }

  int _nowMin() {
    final now = DateTime.now();
    return now.hour * 60 + now.minute;
  }

  @override
  Widget build(BuildContext context) {
    final isToday = _dateStr == DateFormat('yyyy-MM-dd').format(_today);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          children: [
            Text('第${_week ?? '?'}周 · ${_weekday(_date.weekday)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              DateFormat('M月d日').format(_date),
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        leading: IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
        actions: [
          if (!isToday)
            TextButton(
              onPressed: () {
                setState(() => _date = _today);
                _load();
              },
              child: const Text('今天'),
            ),
          IconButton(
            icon: const Icon(Icons.schedule_outlined),
            tooltip: '未排期',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen())),
          ),
        ],
      ),
      body: _buildBody(isToday),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(null),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody(bool isToday) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 8),
            ElevatedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return TimelineView(
      items: _items,
      isToday: isToday,
      nowMin: _nowMin(),
      onTapEmpty: (s, e) => _openEditor(null, startMin: s, endMin: e),
      onTapItem: (item) => _openEditor(item),
    );
  }

  Future<void> _openEditor(TimelineItem? item, {int? startMin, int? endMin}) async {
    if (item?.type == 'class') {
      await showCourseDetails(context, item!);
      return;
    }
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BlockEditor(
          date: _dateStr,
          item: item,
          startMin: startMin,
          endMin: endMin,
        ),
      ),
    );
    if (changed == true) _load();
  }

  static String _weekday(int wd) => const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][wd];
}
