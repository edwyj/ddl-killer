import test from 'node:test';
import assert from 'node:assert/strict';
const dates=await import('../src/ai-request-dates.js').catch(()=>({}));
test('next week uses Monday based weeks, independent of a narrow client range',()=>{
 assert.equal(typeof dates.planningRequestDates,'function');
 const r=dates.planningRequestDates('下周六要做合成作业',[],{date:'2026-10-08'});
 assert.equal(r[0].date,'2026-10-17');
 const monday=dates.planningRequestDates('下周日出去',[],{date:'2026-10-05'});
 assert.equal(monday[0].date,'2026-10-18');
 assert.equal(dates.planningRequestDates('下周天',[],{date:'2026-10-08'})[0].date,'2026-10-18');
 assert.equal(dates.planningRequestDates('本周六',[],{date:'2026-10-08'})[0].date,'2026-10-10');
});
test('short follow-ups retain date evidence without treating assistant text as user instructions',()=>{
 assert.equal(typeof dates.planningRequestDates,'function');
 const r=dates.planningRequestDates('按你的理解先排',[{input:'下周六完成合成作业',summary:'本周六'}],{date:'2026-10-08'});
 assert.deepEqual(r.map(x=>[x.text,x.date]),[['下周六','2026-10-17']]);
 const correction=dates.planningRequestDates('改成下周日',[{input:'下周六'}],{date:'2026-10-08'});
 assert.equal(correction.at(-1).date,'2026-10-18');
});
