import {randomUUID} from 'node:crypto';
import {db} from './db.js';
import {planningPreferences} from './ai-availability.js';

export const REQUIREMENT_KINDS=['start_minute','end_minute','break_minutes','task_duration','preserve_task'];
const taskKinds=new Set(['task_duration','preserve_task']);
export function requirementError(message='助手没能正确整理本次要求，你可以继续说明希望怎样安排') {
  return Object.assign(new Error(message),{code:'AI_REQUIREMENTS_INVALID'});
}
function invalid(code,message){return Object.assign(requirementError(),{issues:[{code,message}]});}
function normalized(userId,raw,{message,manual=false}={}) {
  if(!raw || typeof raw!=='object' || Array.isArray(raw) ||
    Object.keys(raw).some(k=>!['kind','taskId','value','source'].includes(k)) || !REQUIREMENT_KINDS.includes(raw.kind)) throw invalid('REQUIREMENT_SHAPE','要求只能包含kind、taskId、value、source四个字段及合法kind');
  const {kind,value}=raw,taskId=raw.taskId??null;
  if(!Number.isInteger(value)) throw requirementError();
  if(taskKinds.has(kind) || taskId!==null && ['start_minute','end_minute'].includes(kind)) {
    if(!Number.isSafeInteger(taskId) || !db.prepare('SELECT 1 FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL').get(taskId,userId)) throw invalid('REQUIREMENT_TASK_UNKNOWN','task_duration和preserve_task必须引用context.tasks中的已有任务ID。新任务的耗时只填create_task.estimateMinutes，不要为新任务或独立日程生成耗时requirements');
  } else if(taskId!==null) throw requirementError();
  if((kind==='start_minute' && (value<0 || value>=1440)) ||
    (kind==='end_minute' && (value<1 || value>1440)) ||
    (kind==='break_minutes' && (value<0 || value>60)) ||
    (kind==='task_duration' && (value<1 || value>10080)) ||
    (kind==='preserve_task' && value!==1)) throw requirementError();
  const source=manual?'在本次要求中设置':raw.source;
  if(typeof source!=='string' || source.length<2 || source.length>240 || (!manual && !message?.includes(source))) throw invalid('REQUIREMENT_SOURCE','source必须是本轮request连续的逐字原文，不得删标点、加空格或从history摘取');
  return {id:randomUUID(),kind,taskId,value,source,confirmed:manual};
}
export function mergeRequirements(userId,old=[],raw=[],message='',{manual=false}={}) {
  if(!Array.isArray(raw) || raw.length>20) throw requirementError();
  const result=new Map(old.map(r=>[`${r.kind}:${r.taskId??''}`,r]));
  const seen=new Set();
  for(const value of raw) {
    const next=normalized(userId,value,{message,manual});
    const key=`${next.kind}:${next.taskId??''}`;
    if(seen.has(key)) throw invalid('REQUIREMENT_DUPLICATE','同一个kind和taskId只能出现一次；不要把具体方案起止时间当作新的长期时间范围'); seen.add(key);
    const prior=result.get(key);
    if(prior?.value===next.value && prior.source===next.source) continue;
    result.set(key,next);
  }
  const all=[...result.values()];
  if(all.length>20 || JSON.stringify(all).length>6000) throw requirementError('本次要求较多，请先清理不再需要的要求');
  effectiveRequirements(userId,all);
  return all;
}
export function effectiveRequirements(userId,requirements=[]) {
  const preferences={...planningPreferences(userId)},durations=new Map(),preserve=new Set(),taskWindows=new Map();
  for(const r of requirements) {
    if(r.kind==='start_minute'||r.kind==='end_minute') {
      const key=r.kind==='start_minute'?'startMinute':'endMinute';
      if(r.taskId==null)preferences[key]=r.value;
      else {const window=taskWindows.get(r.taskId)??{};window[key]=r.value;taskWindows.set(r.taskId,window);}
    }
    if(r.kind==='break_minutes') preferences.breakMinutes=r.value;
    if(r.kind==='task_duration') durations.set(r.taskId,r.value);
    if(r.kind==='preserve_task') preserve.add(r.taskId);
  }
  if(preferences.startMinute>=preferences.endMinute) throw requirementError('结束时间需要晚于开始时间');
  for(const window of taskWindows.values())if((window.startMinute??0)>=(window.endMinute??1440))throw requirementError('任务的结束时间需要晚于开始时间');
  return {preferences,durations,preserve,taskWindows};
}
export function normalizeExceptions(userId,raw=[]) {
  if(!Array.isArray(raw) || raw.length>100) throw requirementError();
  const result=[],seen=new Set();
  for(const r of raw) {
    if(!r || Object.keys(r).some(k=>!['taskId','kind'].includes(k)) || !Number.isSafeInteger(r.taskId) ||
      !['overlap','deadline','rest','window'].includes(r.kind) ||
      !db.prepare('SELECT 1 FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL AND done=0').get(r.taskId,userId)) throw requirementError();
    const key=`${r.taskId}:${r.kind}`;if(seen.has(key)) throw requirementError();seen.add(key);
    result.push({taskId:r.taskId,kind:r.kind});
  }
  return result;
}
export function visibleRequirements(userId,requirements=[]) {
  return requirements.map(r=>({...r,taskTitle:r.taskId?db.prepare('SELECT title FROM inbox WHERE id=? AND user_id=?').get(r.taskId,userId)?.title??'任务':null}));
}
