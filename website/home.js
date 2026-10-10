
(() => {
 const root=document.getElementById('ddl-home-refine'),template=root.querySelector('#ddl-refine-template');
 const scenes=[
  {prompt:'明天交报告，今晚还想复习高数，帮我排一下。',answer:'报告放在上午，复习留到晚饭后。避开下午课程，中间留出休息时间。',fixed:['14:30','写作课','14:30–16:00'],rows:[['10:00','整理报告资料','10:00–11:30'],['19:30','高数复习','19:30–20:15']],alt:[['11:00','整理报告资料','11:00–12:30'],['19:00','高数复习','19:00–19:45']]},
  {prompt:'把概念梳理和错题练习排到这两天，晚上别太晚。',answer:'概念梳理放在周二，错题练习放在周三。两项都放在较早的晚间时段。',fixed:['周三','实践课','14:00–15:30'],rows:[['周二','概念梳理','19:00–19:45'],['周三','错题练习','18:30–19:30']],alt:[['周二','概念梳理','18:00–18:45'],['周三','错题练习','19:00–20:00']]},
  {prompt:'这周要做项目、读书和运动，给我留一个空闲的晚上。',answer:'项目放在周初，阅读和运动放到周末。周四晚上留空，你可以休息或临时调整。',fixed:['周一','整理项目说明','16:00–17:30'],rows:[['周六','阅读','10:00–11:00'],['周日','运动','15:00–16:00']],alt:[['周六','阅读','15:00–16:00'],['周日','运动','10:00–11:00']]}
 ];
 const saved=[],views=[];
 const persist=()=>{};
 root.querySelectorAll('[data-view]').forEach(page=>{
  page.append(template.content.cloneNode(true));const name=page.dataset.view,prior=saved.find(v=>v.name===name);
  const state={scene:Number.isInteger(prior?.scene)&&prior.scene>=0&&prior.scene<3?prior.scene:0,applied:prior?.applied===true,adjusted:prior?.adjusted===true,feature:['list','ddl','timeline','course'].includes(prior?.feature)?prior.feature:'list',theme:['light','dark'].includes(prior?.theme)?prior.theme:'system'};
  const q=s=>page.querySelector(s),all=s=>[...page.querySelectorAll(s)];let run=0;
  const theme=()=>{};
  const render=()=>{
   const scene=scenes[state.scene],timeline=q('[data-timeline]');timeline.replaceChildren();
   const add=(row,course)=>{const time=document.createElement('span');time.className='r-time';time.textContent=row[0];const item=document.createElement('div');item.className='r-event '+(course?'course':state.applied?'applied':'draft');const title=document.createElement('span');title.textContent=row[1];const duration=document.createElement('small');duration.textContent=row[2];item.append(title,duration);timeline.append(time,item);};
   const rows=state.adjusted?scene.alt:scene.rows;
   if(state.scene===0){add(rows[0],false);add(scene.fixed,true);add(rows[1],false);}else{add(scene.fixed,true);rows.forEach(r=>add(r,false));}
   q('[data-prompt]').textContent=scene.prompt;q('[data-answer]').textContent=state.applied?'已经加入示例日程。你还可以调整时间，也可以撤销这次示例安排。':state.adjusted?'已经换了一组时间，原有课程保持不变。看看这版是否更合适，满意后再确认。':scene.answer;
   q('[data-status]').textContent=state.applied?'已加入示例日程':'方案已生成 · 等待你确认';q('[data-confirm]').hidden=state.applied;q('[data-adjust]').hidden=state.applied;q('[data-undo]').hidden=!state.applied;q('[data-adjust]').textContent=state.adjusted?'恢复原方案':'换个时间';
   all('[data-scene]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.scene)===state.scene)));
   all('[data-feature]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.feature===state.feature)));all('[data-panel]').forEach(p=>p.hidden=p.dataset.panel!==state.feature);theme();
  };
  const replay=async index=>{const token=++run;state.scene=index;state.applied=false;state.adjusted=false;render();if(matchMedia('(prefers-reduced-motion: reduce)').matches){persist();return;}const answer=q('[data-answer]'),value=scenes[index].answer;answer.textContent='';q('[data-status]').textContent='正在整理示例方案…';q('[data-confirm]').disabled=true;q('[data-adjust]').disabled=true;for(const character of value){if(run!==token)return;answer.textContent+=character;await new Promise(resolve=>setTimeout(resolve,18));}if(run!==token)return;q('[data-status]').textContent='方案已生成 · 等待你确认';q('[data-confirm]').disabled=false;q('[data-adjust]').disabled=false;persist();};
  all('[data-scene]').forEach(b=>b.addEventListener('click',()=>replay(Number(b.dataset.scene))));q('[data-replay]').addEventListener('click',()=>replay(state.scene));
  q('[data-confirm]').addEventListener('click',()=>{++run;state.applied=true;render();persist();});q('[data-adjust]').addEventListener('click',()=>{++run;state.adjusted=!state.adjusted;render();persist();});q('[data-undo]').addEventListener('click',()=>{++run;state.applied=false;render();persist();});
  all('[data-feature]').forEach(b=>b.addEventListener('click',()=>{state.feature=b.dataset.feature;render();persist();}));
  all('[data-palette]').forEach(b=>b.addEventListener('click',()=>{q('.r-personal-example').dataset.color=b.dataset.palette;all('[data-palette]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));}));
  all('.r-task').forEach(row=>{const box=row.querySelector('input'),caption=row.querySelector('small'),original=caption.textContent==='已完成'?'待安排':caption.textContent;box.addEventListener('change',()=>caption.textContent=box.checked?'已完成':original);});
    const menu=q('.r-menu'),nav=q('.r-mobile-nav');const close=()=>{nav.hidden=true;menu.setAttribute('aria-expanded','false');menu.setAttribute('aria-label','打开导航');};
  menu.addEventListener('click',()=>{const opening=nav.hidden;nav.hidden=!opening;menu.setAttribute('aria-expanded',String(opening));menu.setAttribute('aria-label',opening?'关闭导航':'打开导航');});page.addEventListener('keydown',event=>{if(event.key==='Escape')close();});
  all('[data-scroll]').forEach(a=>a.addEventListener('click',event=>{event.preventDefault();close();q('[data-section="'+a.dataset.scroll+'"]').scrollIntoView({block:'start',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});}));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change',()=>{if(state.theme==='system')theme();});
  views.push({name,state,render});render();
 });
})();
