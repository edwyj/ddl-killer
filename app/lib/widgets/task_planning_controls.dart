import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../reminders.dart';
import '../screens/reminder_settings_screen.dart';

class TaskPlanningControls extends StatelessWidget {
  const TaskPlanningControls({super.key, required this.schedule, required this.reminder,
    required this.onSchedule, required this.onReminder, required this.busy, this.dueDate, this.dueTime});
  final Map<String,dynamic>? schedule;
  final DateTime? reminder;
  final String? dueDate;
  final int? dueTime;
  final bool busy;
  final ValueChanged<Map<String,dynamic>?> onSchedule;
  final ValueChanged<DateTime?> onReminder;

  Future<DateTime?> _dateTime(BuildContext context, DateTime initial) async {
    final day=await showDatePicker(context: context, initialDate: initial,
      firstDate: DateTime(2020), lastDate: DateTime(2100));
    if(day==null || !context.mounted)return null;
    final time=await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    return time==null ? null : DateTime(day.year,day.month,day.day,time.hour,time.minute);
  }
  Future<void> _plan(BuildContext context) async {
    final initial=schedule==null ? DateTime.now().add(const Duration(hours:1))
      : DateTime.parse(schedule!['date'] as String).add(Duration(minutes: schedule!['start_min'] as int));
    final start=await _dateTime(context,initial);
    if(start==null || !context.mounted)return;
    final defaultEnd=(start.hour*60+start.minute+60).clamp(1,1439);
    final end=await showTimePicker(context: context,initialTime: TimeOfDay(hour:defaultEnd~/60,minute:defaultEnd%60),helpText:'结束时间（同一天）');
    if(end==null || !context.mounted)return;
    final startMin=start.hour*60+start.minute, endMin=end.hour*60+end.minute;
    if(endMin<=startMin) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('结束时间需要晚于开始时间')));return; }
    onSchedule({'date':DateFormat('yyyy-MM-dd').format(start),'start_min':startMin,'end_min':endMin});
  }
  Future<void> _remind(BuildContext context,int choice) async {
    if(choice==-2) { onReminder(null); return; }
    DateTime? result;
    if(choice==-1) {
      result=await _dateTime(context,reminder ?? DateTime.now().add(const Duration(hours:1)));
    } else if(dueDate!=null) {
      result=DateTime.parse(dueDate!).add(Duration(minutes:dueTime??540)).subtract(Duration(minutes:choice));
    }
    if(result==null || !context.mounted)return;
    if(!result.isAfter(DateTime.now())) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('请选择未来的提醒时间')));return; }
    onReminder(result);
  }
  String _time(int m)=>'${(m~/60).toString().padLeft(2,'0')}:${(m%60).toString().padLeft(2,'0')}';
  @override
  Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.edit_calendar_outlined),
      title:const Text('安排到日历'), subtitle:Text(schedule==null ? '选择实际做这件事的时间，不改变截止日期'
        : '${schedule!['date']}  ${_time(schedule!['start_min'] as int)}–${_time(schedule!['end_min'] as int)}'),
      onTap:busy?null:()=>_plan(context), trailing:schedule==null?const Icon(Icons.chevron_right)
        : IconButton(tooltip:'取消时间安排，保留任务',onPressed:busy?null:()=>onSchedule(null),icon:const Icon(Icons.close))),
    PopupMenuButton<int>(enabled:!busy,onSelected:(v)=>_remind(context,v),itemBuilder:(_)=>[
      const PopupMenuItem(value:-2,child:Text('不提醒')),
      if(dueDate!=null)...[
        PopupMenuItem(value:0,child:Text(dueTime==null?'截止当天 09:00':'截止时提醒')),
        const PopupMenuItem(value:60,child:Text('提前 1 小时')),
        const PopupMenuItem(value:1440,child:Text('提前 1 天')),
      ],
      const PopupMenuItem(value:-1,child:Text('自定义提醒时间')),
    ],child:ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.notifications_outlined),
      title:const Text('提醒'),subtitle:Text(reminder==null?'未设置':DateFormat('yyyy-MM-dd HH:mm').format(reminder!)),trailing:const Icon(Icons.expand_more))),
    ValueListenableBuilder<String>(valueListenable:Reminders.status,builder:(_,text,_)=>TextButton(
      onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>const ReminderSettingsScreen())),
      child:Text('$text · 设置',style:const TextStyle(fontSize:12)))),
  ]);
}
