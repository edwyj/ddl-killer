import test from 'node:test';
import assert from 'node:assert/strict';
process.env.DB_PATH=':memory:';
const {db}=await import('../src/db.js');
const {saveTask}=await import('../src/task-planning.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const rules=await import('../src/ai-plan-rules.js').catch(()=>({}));
const requirements=await import('../src/ai-requirements.js').catch(()=>({}));
const uid=createUserWithDefaultLists('rules_owner','unused');
const other=createUserWithDefaultLists('rules_other','unused');
const date=new Date(Date.now()+3*86400000).toISOString().slice(0,10);
const task=saveTask(uid,null,{title:'合成任务甲',estimate_minutes:60,due_date:date,due_time:720,schedule:{date,start_min:600,end_min:660}});
const second=saveTask(uid,null,{title:'合成任务乙',estimate_minutes:30});
const change=(taskId,start=660,end=start+60)=>({op:'schedule_task',taskId,date,start,end});
test.after(()=>db.close());
test('per-task time windows remain separate from the overall day and survive corrections',()=>{
  const input='甲在10:00到11:00，乙在12:00到13:00，全部22点前结束';
  const state=requirements.mergeRequirements(uid,[],[
    {kind:'start_minute',taskId:task.id,value:600,source:'甲在10:00到11:00'},
    {kind:'end_minute',taskId:task.id,value:660,source:'甲在10:00到11:00'},
    {kind:'start_minute',taskId:second.id,value:720,source:'乙在12:00到13:00'},
    {kind:'end_minute',taskId:second.id,value:780,source:'乙在12:00到13:00'},
    {kind:'end_minute',taskId:null,value:1320,source:'全部22点前结束'},
  ],input);
  assert.equal(requirements.effectiveRequirements(uid,state).preferences.endMinute,1320);
  assert.deepEqual(rules.validateAiPlan(uid,[change(task.id,600,660),change(second.id,720,780)],state),[]);
  assert.ok(rules.validateAiPlan(uid,[change(task.id,660,720)],state).some(w=>w.code==='TASK_WINDOW_VIOLATION'));
  const corrected=requirements.mergeRequirements(uid,state,[{kind:'end_minute',taskId:task.id,value:690,source:'甲改成11:30结束'}],'甲改成11:30结束');
  assert.equal(corrected.find(r=>r.kind==='end_minute'&&r.taskId===second.id).value,780);
  assert.equal(corrected.find(r=>r.kind==='end_minute'&&r.taskId==null).value,1320);
});

test('AI rules release moved positions but reject overlap, deadline and insufficient duration',()=>{
  assert.equal(typeof rules.validateAiPlan,'function');
  assert.deepEqual(rules.validateAiPlan(uid,[change(task.id,660,720)]),[]);
  assert.equal(rules.validateAiPlan(uid,[change(second.id,615,645)])[0].code,'TIME_OVERLAP');
  assert.ok(rules.validateAiPlan(uid,[change(task.id,690,750)]).some(w=>w.code==='DEADLINE_EXCEEDED'));
  assert.ok(rules.validateAiPlan(uid,[change(task.id,660,690)]).some(w=>w.code==='DURATION_TOO_SHORT'));
  assert.ok(rules.validateAiPlan(uid,[change(task.id,480,540),change(second.id,525,555)]).some(w=>w.code==='TIME_OVERLAP'));
});
test('partial selection checks unchanged task positions, rest and unknown duration',()=>{
  assert.equal(typeof rules.validateAiPlan,'function');
  assert.equal(rules.validateAiPlan(uid,[change(second.id,600,630)])[0].code,'TIME_OVERLAP');
  assert.ok(rules.validateAiPlan(uid,[change(second.id,660,690)]).some(w=>w.code==='REST_TOO_SHORT'));
  const unknown=saveTask(uid,null,{title:'耗时未知'});
  assert.ok(rules.validateAiPlan(uid,[change(unknown.id,780,840)]).some(w=>w.code==='DURATION_UNKNOWN'));
});
test('requirements retain source evidence, corrections and ownership; model cannot grant exceptions',()=>{
  assert.equal(typeof requirements.mergeRequirements,'function');
  const first=requirements.mergeRequirements(uid,[],[{kind:'end_minute',taskId:null,value:1320,source:'22点前结束'}],'请22点前结束');
  assert.equal(first[0].confirmed,false);
  const next=requirements.mergeRequirements(uid,first,[{kind:'end_minute',taskId:null,value:1260,source:'21点前结束'}],'改成21点前结束');
  assert.equal(next.length,1);assert.equal(next[0].value,1260);
  assert.throws(()=>requirements.mergeRequirements(uid,[],[{kind:'end_minute',taskId:null,value:1200,source:'20点前结束'}],'别的原话'));
  const foreignTask=saveTask(other,null,{title:'其他账号任务'});
  assert.throws(()=>requirements.mergeRequirements(uid,[],[{kind:'task_duration',taskId:foreignTask.id,value:30,source:'30分钟'}],'30分钟'));
  assert.throws(()=>requirements.mergeRequirements(uid,[],[{kind:'allow_overlap',taskId:task.id,value:1,source:'允许重叠'}],'允许重叠'));
});
