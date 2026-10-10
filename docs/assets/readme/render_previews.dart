// Documentation asset generator. Not part of the application test suite.
// Run render-previews.ps1 in this directory; all data below is fictional.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/api.dart';
import 'package:plan_app/models/ai_planner.dart';
import 'package:plan_app/screens/ai_planner_sheet.dart';
import 'package:plan_app/screens/ddl_screen.dart';
import 'package:plan_app/screens/list_screen.dart';
import 'package:plan_app/screens/week_screen.dart';
import 'package:plan_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _demoDay = '2026-10-08';
final _demoNow = DateTime(2026, 10, 8, 8);
const _previewKey = ValueKey('readme-preview');
const _exportScale = 3.0;

Map<String, Object> _entry(
  String title,
  int start,
  int end, {
  bool course = false,
  String color = '#9E8BCB',
  int id = 1,
}) => {
  'type': course ? 'class' : 'task',
  if (!course) 'id': id,
  'title': title,
  'start_min': start,
  'end_min': end,
  'color': color,
  if (course) 'room': '示例教学楼',
  if (course) 'weekNum': 6,
};

final _today = [
  _entry('高等数学', 480, 580, course: true, color: '#A38BCD'),
  _entry('整理课堂笔记', 630, 675, id: 1),
  _entry('大学英语', 840, 940, course: true, color: '#D990B0'),
  _entry('小组项目讨论', 990, 1050, color: '#B494C7', id: 2),
];

final _deadlines = [
  {'id': 11, 'title': '提交程序设计作业', 'due_date': _demoDay, 'due_time': 1320},
  {'id': 12, 'title': '上传实验报告', 'due_date': _demoDay, 'due_time': 1080},
  {'id': 13, 'title': '确认小组展示分工', 'due_date': _demoDay, 'due_time': 1200},
  {'id': 14, 'title': '小组项目阶段汇报', 'due_date': '2026-10-13', 'due_time': 900},
  {'id': 15, 'title': '复习线性代数', 'due_date': '2026-10-16', 'due_time': 1200},
  {'id': 16, 'title': '图书馆借书', 'due_date': _demoDay, 'done': 1},
];

final _weekEntries = [
  [
    _entry('高等数学', 480, 580, course: true, color: '#A38BCD'),
    _entry('程序设计', 600, 700, course: true, color: '#D990B0'),
    _entry('午休', 740, 780, id: 31, color: '#C3ACC9'),
    _entry('写实验报告', 840, 930, id: 21, color: '#AC9AD9'),
    _entry('跑步', 1020, 1080, id: 22, color: '#C69BBC'),
    _entry('高数习题练习', 1140, 1230, id: 32, color: '#AC9AD9'),
    _entry('睡前阅读', 1240, 1270, id: 33, color: '#C69BBC'),
  ],
  [
    _entry('英语听力', 510, 550, id: 34, color: '#AC9AD9'),
    _entry('大学英语', 600, 700, course: true, color: '#D990B0'),
    _entry('午休', 750, 800, id: 35, color: '#C3ACC9'),
    _entry('线性代数', 840, 940, course: true, color: '#8E91CB'),
    _entry('整理课堂笔记', 990, 1035, id: 23, color: '#AC9AD9'),
    _entry('社团例会', 1140, 1230, id: 36, color: '#C69BBC'),
  ],
  [
    _entry('高等数学', 480, 580, course: true, color: '#A38BCD'),
    _entry('准备英语展示', 630, 690, id: 24, color: '#C69BBC'),
    _entry('午休', 740, 790, id: 37, color: '#C3ACC9'),
    _entry('程序设计实验', 840, 960, course: true, color: '#D990B0'),
    _entry('打羽毛球', 990, 1050, id: 38, color: '#C69BBC'),
    _entry('整理实验数据', 1140, 1215, id: 39, color: '#AC9AD9'),
  ],
  [
    ..._today,
    _entry('午休', 735, 785, id: 40, color: '#C3ACC9'),
    _entry('英语口语练习', 1140, 1200, id: 41, color: '#AC9AD9'),
    _entry('读一本喜欢的书', 1215, 1260, id: 42, color: '#C69BBC'),
  ],
  [
    _entry('线性代数', 480, 580, course: true, color: '#8E91CB'),
    _entry('小组原型讨论', 630, 690, id: 43, color: '#AC9AD9'),
    _entry('午休', 750, 800, id: 44, color: '#C3ACC9'),
    _entry('完成项目原型', 840, 960, id: 25, color: '#AC9AD9'),
    _entry('社团活动', 1020, 1080, id: 26, color: '#C69BBC'),
    _entry('本周课程回顾', 1140, 1230, id: 45, color: '#AC9AD9'),
  ],
  [
    _entry('图书馆自习', 540, 660, id: 27, color: '#AC9AD9'),
    _entry('午饭与休息', 720, 810, id: 46, color: '#C3ACC9'),
    _entry('和朋友看电影', 870, 990, id: 28, color: '#C69BBC'),
    _entry('打篮球', 1020, 1080, id: 47, color: '#C69BBC'),
    _entry('读书', 1170, 1230, id: 48, color: '#AC9AD9'),
  ],
  [
    _entry('复习本周内容', 570, 660, id: 29, color: '#AC9AD9'),
    _entry('整理宿舍', 670, 720, id: 49, color: '#C69BBC'),
    _entry('和家人通话', 840, 880, id: 50, color: '#C69BBC'),
    _entry('规划下一周', 960, 1005, id: 30, color: '#C69BBC'),
    _entry('看英语短片', 1140, 1200, id: 51, color: '#AC9AD9'),
  ],
];

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

MockClient _client({bool deadlines = false}) => MockClient((request) async {
  Object response = [];
  switch (request.url.path) {
    case '/api/day':
      response = {'timeline': _today};
    case '/api/inbox':
      response = deadlines ? _deadlines : [_deadlines.first];
    case '/api/days':
      final start = DateTime.parse(request.url.queryParameters['start']!);
      response = {
        'weekNum': 6,
        'days': [
          for (var i = 0; i < 7; i++)
            {
              'date': _date(start.add(Duration(days: i))),
              'weekday': i + 1,
              'timeline': _weekEntries[i],
            },
        ],
      };
  }
  return http.Response(
    jsonEncode(response),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

Widget _ddlIcon(BuildContext context, {required bool selected}) {
  final scheme = Theme.of(context).colorScheme;
  return Text(
    'DDL',
    style: TextStyle(
      fontSize: 14,
      height: 1,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.3,
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    ),
  );
}

// Keep this documentation host in step with RootScreen's current navigation.
Widget _navigation(BuildContext context, int selected) => NavigationBar(
  height: 72,
  selectedIndex: selected,
  onDestinationSelected: (_) {},
  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
  destinations: [
    const NavigationDestination(
      icon: Icon(Icons.checklist_outlined),
      selectedIcon: Icon(Icons.checklist),
      label: '',
    ),
    const NavigationDestination(
      icon: Icon(Icons.calendar_month_outlined),
      selectedIcon: Icon(Icons.calendar_month),
      label: '',
    ),
    NavigationDestination(
      icon: _ddlIcon(context, selected: false),
      selectedIcon: _ddlIcon(context, selected: true),
      label: '',
    ),
    const NavigationDestination(
      icon: Badge(
        isLabelVisible: false,
        label: Text('0'),
        child: Icon(Icons.settings_outlined),
      ),
      selectedIcon: Badge(
        isLabelVisible: false,
        label: Text('0'),
        child: Icon(Icons.settings),
      ),
      label: '我的',
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester,
  Widget screen, {
  int? selected,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(AppColorTheme.lilac).copyWith(
        // Static documentation images omit scroll indicators; widgets are unchanged.
        scrollbarTheme: const ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(0),
          thumbColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      home: RepaintBoundary(
        key: _previewKey,
        child: selected == null
            ? screen
            : Builder(
                builder: (context) => Scaffold(
                  body: SafeArea(bottom: false, child: screen),
                  bottomNavigationBar: _navigation(context, selected),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _save(WidgetTester tester, String name) async {
  expect(tester.takeException(), isNull);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_previewKey),
  );
  // Finder-based golden capture always uses 1x, regardless of screen density.
  // Render the same logical layout at 3x directly; do not upscale an existing PNG.
  final image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: _exportScale),
  );
  expect(image, isNotNull);
  expect(image!.width, (boundary.size.width * _exportScale).round());
  expect(image.height, (boundary.size.height * _exportScale).round());
  try {
    await expectLater(
      image,
      matchesGoldenFile('../../docs/assets/readme/$name.png'),
    );
  } finally {
    image.dispose();
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

Future<void> _withRealShadows(Future<void> Function() render) async {
  // Restore inside the test body: Flutter checks painting flags before tearDown.
  final previousShadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    await render();
  } finally {
    debugDisableShadows = previousShadows;
  }
}

class _DemoPlanner implements AiPlannerRepository {
  @override
  Future<AiTurnResult> createSession(
    String message,
    DateTime start,
    DateTime end,
  ) async => AiTurnResult(
    sessionId: 'fictional-preview',
    draft: const AiDraft(
      id: 'fictional-draft',
      status: 'pending',
      changes: [
        AiDraftChange(
          id: 'demo-1',
          operation: 'schedule_task',
          title: '整理实验报告',
          date: _demoDay,
          start: 600,
          end: 660,
          before: '未安排',
          reason: '避开上午课程，留出一小时专心完成。',
        ),
        AiDraftChange(
          id: 'demo-2',
          operation: 'schedule_task',
          title: '复习高等数学',
          date: _demoDay,
          start: 1140,
          end: 1185,
          before: '未安排',
          reason: '晚饭后复习，保留午休和晚间休息。',
        ),
      ],
      warnings: [],
    ),
    summary: '给你留好了上课和午休的时间，先完成临近截止的实验报告。',
    questions: const [],
    warnings: const [],
    quota: AiQuota(
      limit: 3,
      used: 1,
      reserved: 0,
      remaining: 2,
      resetsAt: DateTime.utc(2026, 10, 9),
      hostedEnabled: true,
      copy: '',
    ),
  );
  @override
  Future<AiTurnResult> addTurn(String sessionId, String message) =>
      createSession(message, _demoNow, _demoNow);
  @override
  Future<List<AiSessionSummary>> listSessions() async => [];
  @override
  Future<AiSessionDetail> getSession(String sessionId) =>
      throw UnimplementedError('This preview has no saved sessions.');
  @override
  Future<void> closeSession(String sessionId) async {}
  @override
  Future<void> deleteSession(String sessionId) async {}
  @override
  Future<void> applyDraft(String draftId) async {}
}

void main() {
  setUpAll(() async {
    for (final entry in {
      'Ahem': 'assets/fonts/NotoSansSC.ttf',
      'NotoSansSC': 'assets/fonts/NotoSansSC.ttf',
      'NotoColorEmoji': 'assets/fonts/NotoColorEmoji.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Api.instance.network.reset();
  });
  testWidgets('render documentation Today', (tester) async {
    await _withRealShadows(() async {
      await http.runWithClient(() async {
        await _mount(tester, ListScreen(now: () => _demoNow), selected: 0);
        await _save(tester, 'today');
      }, _client);
    });
  });
  testWidgets('render documentation week', (tester) async {
    await _withRealShadows(() async {
      await http.runWithClient(() async {
        await _mount(
          tester,
          const WeekScreen(),
          selected: 1,
          size: const Size(1200, 860),
        );
        await _save(tester, 'week');
      }, _client);
    });
  });
  testWidgets('render documentation DDL', (tester) async {
    await _withRealShadows(() async {
      await http.runWithClient(() async {
        await _mount(tester, DdlScreen(now: () => _demoNow), selected: 2);
        await _save(tester, 'deadlines');
      }, () => _client(deadlines: true));
    });
  });
  testWidgets('render documentation Alice', (tester) async {
    await _withRealShadows(() async {
      await _mount(
        tester,
        Scaffold(body: AiPlannerSheet(repository: _DemoPlanner())),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-planner-input')),
        '帮我安排实验报告和高数复习，避开上课和午休。',
      );
      await tester.tap(find.byTooltip('生成安排'));
      await tester.pumpAndSettle();
      await _save(tester, 'alice');
    });
  });
}
