import {db} from './db.js';
import {getDayClasses,getUserSchedule} from './schedule.js';
import {localClock} from './ai-availability.js';
import {effectiveRequirements} from './ai-requirements.js';

const overlaps=(a,b)=>a.start<b.end && b.start<a.end;
export function validateAiPlan(userId,changes,requirements=[],exceptions=[],{checkDuration=true,checkPast=true}={}) {
  const {preferences,durations,preserve,taskWindows}=effectiveRequirements(userId,requirements);
  const moved=new Set(changes.filter(c=>c.taskId!=null).map(c=>c.taskId));
  const candidates=changes.filter(c=>c.op!=='unschedule_task' && c.date);
  const schedule=getUserSchedule(userId),clock=localClock(),issues=[];
  const permitted=(taskId,kind)=>taskId!=null && exceptions.some(e=>e.taskId===taskId && e.kind===kind);
  const add=(code,message,c,index,exception)=>issues.push({code,message,taskId:c.taskId??null,index,severity:exception?'warning':'blocking'});
  const byDate=new Map();
  const titleKey=t=>t.normalize('NFKC').replace(/\s/g,'').toLowerCase();
  const existingTitles=new Set(changes.some(c=>c.op==='create_task')?
    db.prepare('SELECT title FROM inbox WHERE user_id=? AND deleted_at IS NULL AND done=0').all(userId).map(t=>titleKey(t.title)):[]);
  const newTitles=new Set();
  for(let index=0;index<changes.length;index++) {
    const c=changes[index];
    if(c.op==='create_task') {
      const key=titleKey(c.title);
      if(existingTitles.has(key)||newTitles.has(key))add('TASK_ALREADY_EXISTS','任务列表已有同名任务，请重新生成并使用已有任务',c,index);
      newTitles.add(key);
    }
    const task=c.taskId==null?null:db.prepare('SELECT * FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL AND done=0').get(c.taskId,userId);
    if(c.taskId!=null && !task){add('OBJECT_NOT_FOUND','该任务已变化，请重新规划',c,index);continue;}
    if(preserve.has(c.taskId)) {
      const block=db.prepare('SELECT * FROM blocks WHERE inbox_id=? AND user_id=? AND deleted_at IS NULL').get(c.taskId,userId);
      if(c.op==='unschedule_task'||!block||c.date!==block.date||c.start!==block.start_min||c.end!==block.end_min)
        add('PRESERVED_TASK','这项任务需要保持原安排，请调整方案',c,index);
    }
    if(c.op==='unschedule_task'||!c.date)continue;
    if(!byDate.has(c.date)) {
      const existing=db.prepare('SELECT id,inbox_id,start_min,end_min,version FROM blocks WHERE user_id=? AND date=? AND deleted_at IS NULL').all(userId,c.date)
        .filter(b=>!moved.has(b.inbox_id)).map(b=>({start:b.start_min,end:b.end_min,...b}));
      const courses=schedule?getDayClasses(schedule,c.date).map(b=>({start:b.start_min,end:b.end_min})):[];
      byDate.set(c.date,{existing,courses});
    }
    const {existing,courses}=byDate.get(c.date);
    const others=candidates.filter(other=>other!==c&&other.date===c.date);
    if(courses.some(b=>overlaps(c,b)))add('COURSE_CONFLICT',`${c.date} 的安排与课程冲突，请换一个时段`,c,index);
    if([...existing,...others].some(b=>overlaps(c,b)))add('TIME_OVERLAP',`${c.date} 的安排与其他安排重叠`,c,index,permitted(c.taskId,'overlap'));
    if(checkPast&&(c.date<clock.date||(c.date===clock.date&&c.start<clock.minute)))add('PAST_TIME','安排时间已过去，请重新规划',c,index);
    const dueDate=c.op==='create_task'?c.dueDate:task?.due_date,dueTime=c.op==='create_task'?c.dueTime:task?.due_time;
    if(dueDate&&(c.date>dueDate||(c.date===dueDate&&c.end>(dueTime??1440))))
      add('DEADLINE_EXCEEDED','有任务结束晚于截止时间，请缩减内容或重新分配时间',c,index,permitted(c.taskId,'deadline'));
    const estimate=c.op==='create_task'?c.estimateMinutes:durations.get(c.taskId)??task?.estimate_minutes;
    if((task||c.op==='create_task')&&checkDuration) {
      if(estimate==null)add('DURATION_UNKNOWN','这项任务还不确定需要多久，请先补充预计用时',c,index);
      else if(c.end-c.start<Math.ceil(estimate/15)*15)add('DURATION_TOO_SHORT','安排的时间不够完成这项任务，请增加时长',c,index);
    }
    if(c.start<preferences.startMinute||c.end>preferences.endMinute)
      add('WINDOW_VIOLATION','安排超出了本次可用时段，请确认时间要求',c,index,permitted(c.taskId,'window'));
    const taskWindow=taskWindows.get(c.taskId);
    if(taskWindow&&(c.start<(taskWindow.startMinute??0)||c.end>(taskWindow.endMinute??1440)))
      add('TASK_WINDOW_VIOLATION','安排超出了这项任务指定的时间，请调整方案或修改该任务的时间要求',c,index);
    if([...existing,...courses,...others].some(b=>!overlaps(c,b)&&
      (b.end<=c.start?c.start-b.end:b.start-c.end)<preferences.breakMinutes))
      add('REST_TOO_SHORT','两项安排之间没有留够休息时间',c,index,permitted(c.taskId,'rest'));
  }
  return issues;
}
export function assertAiPlan(userId,changes,requirements=[],exceptions=[],options) {
  const issues=validateAiPlan(userId,changes,requirements,exceptions,options);
  if(issues.some(w=>w.severity==='blocking'))throw Object.assign(new Error(issues.filter(w=>w.severity==='blocking').map(w=>w.message).join('；')),
    {code:'AI_PLAN_CONFLICT',issues});
  return issues;
}
