import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plan_app/widgets/task_editor.dart';
import 'package:plan_app/models.dart';

void main() {
  test('task model preserves optional estimated duration', () {
    final task=InboxTask.fromJson({'id':71,'title':'合成耗时任务','estimate_minutes':95});
    expect(task.estimateMinutes,95);
    expect(InboxTask.fromJson({'id':72,'title':'旧任务'}).estimateMinutes,isNull);
  });
  testWidgets('task editor sends duration in minutes and keeps it on failed save', (tester) async {
    Map? saved;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder:(context)=>TextButton(
        onPressed:()=>showTaskEditor(context,lists:const [],task:InboxTask.fromJson({'id':71,'title':'合成耗时任务','estimate_minutes':95})),child:const Text('编辑耗时'))))));
      await tester.tap(find.text('编辑耗时')); await tester.pumpAndSettle();
      final field=find.widgetWithText(TextField,'预计用时（可选）');
      await tester.ensureVisible(field);
      await tester.enterText(field,'120');
      await tester.ensureVisible(find.text('保存')); await tester.tap(find.text('保存')); await tester.pumpAndSettle();
      expect(saved?['estimate_minutes'],120);
      expect(find.text('120'),findsOneWidget);
    },()=>MockClient((r) async { saved=jsonDecode(r.body) as Map; return http.Response(jsonEncode({'error':'暂时无法保存'}),400,headers:{'content-type':'application/json; charset=utf-8'}); }));
  });
  testWidgets('editing retains linked schedule; failed save keeps input and permits retry', (tester) async {
    Map? saved;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder:(context)=>TextButton(
        onPressed:()=>showTaskEditor(context,task:const InboxTask(id:55,title:'原任务',schedule:{'date':'2030-04-18','start_min':600,'end_min':660})),child:const Text('编辑'))))));
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('安排到日历'),findsOneWidget);
      await tester.enterText(find.byType(TextField).first,'修改后仍保留');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('修改后仍保留'),findsOneWidget);
      expect(find.text('暂时无法保存'),findsOneWidget);
      expect(saved?['schedule']['start_min'],600);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton,'保存')).onPressed,isNotNull);
    },()=>MockClient((r) async { saved=jsonDecode(r.body) as Map; return http.Response(jsonEncode({'error':'暂时无法保存'}),400,headers:{'content-type':'application/json; charset=utf-8'}); }));
  });
}
