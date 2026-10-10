import { db } from './db.js';
import { DERIVED_SYSTEMS } from './default-lists.js';

const has = (o, k) => Object.hasOwn(o, k);
export function validateSchedule(s) {
  if (s === null) return;
  if (!s || !/^\d{4}-\d{2}-\d{2}$/.test(s.date || '') ||
      !Number.isFinite(Date.parse(s.date)) || new Date(s.date).toISOString().slice(0,10) !== s.date ||
      !Number.isInteger(s.start_min) || !Number.isInteger(s.end_min) ||
      s.start_min < 0 || s.end_min > 1440 || s.start_min >= s.end_min) {
    throw new Error('请选择有效的安排日期和起止时间');
  }
}
export function taskWithSchedule(t) {
  const b = db.prepare('SELECT id,date,start_min,end_min FROM blocks WHERE inbox_id=? AND user_id=? AND deleted_at IS NULL').get(t.id,t.user_id);
  return {...t, schedule:b || null};
}
function transaction(fn) {
  db.exec('SAVEPOINT planning');
  try { const result=fn(); db.exec('RELEASE planning'); return result; }
  catch(e) { db.exec('ROLLBACK TO planning; RELEASE planning'); throw e; }
}
export function saveTask(uid, id, body, {allowPastReminder=false}={}) {
  // 回收站里的任务不参与编辑：先还原再改，否则会出现「改了但看不见」的幽灵任务。
  const old = id == null ? null : db.prepare('SELECT * FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NULL').get(id,uid);
  if (id != null && !old) return null;
  const title = body.title ?? old?.title;
  if(typeof title !== 'string' || !title.trim()) throw new Error('请填写任务标题');
  if(has(body,'schedule')) validateSchedule(body.schedule);
  const estimate = has(body,'estimate_minutes') ? body.estimate_minutes : old?.estimate_minutes ?? null;
  if (estimate !== null && (!Number.isInteger(estimate) || estimate < 1 || estimate > 10080))
    throw new Error('预计用时请填写1至10080分钟，或留空');
  let reminder = has(body,'reminder_at') ? body.reminder_at : old?.reminder_at ?? null;
  if(reminder && (!/^\d{4}-\d{2}-\d{2}T.*Z$/.test(reminder) || !Number.isFinite(Date.parse(reminder)))) throw new Error('提醒时间无效');
  if(reminder) reminder = new Date(reminder).toISOString();
  if(!allowPastReminder && has(body,'reminder_at') && reminder && reminder !== old?.reminder_at && Date.parse(reminder) <= Date.now()) throw new Error('提醒时间必须晚于现在');
  const listId=has(body,'list_id') ? body.list_id : old?.list_id ?? null;
  if(listId) {
    const l = db.prepare('SELECT id,system FROM lists WHERE id=? AND user_id=?').get(listId,uid);
    if(!l) throw new Error('清单不存在');
    // 回收站/已完成的成员是算出来的，手动放进去只会自相矛盾。
    if(DERIVED_SYSTEMS.includes(l.system)) throw new Error('「回收站」「已完成」是自动归集的，不能手动放任务');
  }
  const dueDate=has(body,'due_date') ? body.due_date || null : old?.due_date ?? null;
  const dueTime=has(body,'due_time') ? body.due_time : old?.due_time ?? null;
  if (!has(body,'reminder_at') && old?.reminder_at && old.due_date &&
      (has(body,'due_date') || has(body,'due_time'))) {
    if (!dueDate) reminder = null;
    else {
      const previous = Date.parse(old.due_date + 'T00:00:00Z') + (old.due_time ?? 540) * 60000;
      const next = Date.parse(dueDate + 'T00:00:00Z') + (dueTime ?? 540) * 60000;
      if (!Number.isFinite(next)) throw new Error('截止日期无效');
      reminder = new Date(Date.parse(old.reminder_at) + next - previous).toISOString();
    }
  }
  const done=has(body,'done') ? (body.done?1:0) : old?.done ?? 0;
  // done_at 只在真正翻状态时才动：不传 done 的调用(改标题/改 ddl)不能把完成时刻刷掉，
  // 否则「已完成」列表的排序会乱、3 天到期也会被无限推迟。
  const doneAt = !old
    ? (done ? new Date().toISOString() : null)
    : (done
        ? (old.done ? old.done_at ?? new Date().toISOString() : new Date().toISOString())
        : null);
  return transaction(() => {
    const values=[title.trim(),body.priority ?? old?.priority ?? 0,body.notes ?? old?.notes ?? '',listId,dueDate,dueTime,reminder,done,doneAt];
    const taskKeys=['title','priority','notes','list_id','due_date','due_time','reminder_at','done','done_at'];
    if(old) {
      if(taskKeys.some((key,index) => old[key] !== values[index])) db.prepare('UPDATE inbox SET title=?,priority=?,notes=?,list_id=?,due_date=?,due_time=?,reminder_at=?,done=?,done_at=?,version=version+1 WHERE id=? AND user_id=?').run(...values,id,uid);
    } else id=Number(db.prepare('INSERT INTO inbox(title,priority,notes,list_id,due_date,due_time,reminder_at,done,done_at,user_id) VALUES(?,?,?,?,?,?,?,?,?,?)').run(...values,uid).lastInsertRowid);
    if (!old || old.estimate_minutes !== estimate)
      db.prepare('UPDATE inbox SET estimate_minutes=?,version=version+? WHERE id=? AND user_id=?').run(estimate, old ? 1 : 0, id, uid);
    if(has(body,'schedule')) {
      if(body.schedule === null) db.prepare('DELETE FROM blocks WHERE inbox_id=? AND user_id=?').run(id,uid);
      else {
        const s=body.schedule;
        const color=listId ? db.prepare('SELECT color FROM lists WHERE id=?').get(listId).color : '#5C8DEF';
        const block=db.prepare('SELECT * FROM blocks WHERE inbox_id=? AND user_id=?').get(id,uid);
        if(!block) db.prepare(`INSERT INTO blocks(user_id,inbox_id,date,start_min,end_min,title,notes,list_id,color,done,source)
          VALUES(?,?,?,?,?,?,?,?,?,?,'planned')`).run(uid,id,s.date,s.start_min,s.end_min,title.trim(),values[2],listId,color,done);
        else {
          const next=[s.date,s.start_min,s.end_min,title.trim(),values[2],listId,done];
          const keys=['date','start_min','end_min','title','notes','list_id','done'];
          if(block.deleted_at !== null || keys.some((key,index) => block[key] !== next[index])) {
            db.prepare(`UPDATE blocks SET date=?,start_min=?,end_min=?,title=?,notes=?,list_id=?,done=?,deleted_at=NULL,version=version+1
              WHERE id=? AND user_id=?`).run(...next,block.id,uid);
          }
        }
      }
    }
    const linked=db.prepare('SELECT id,title,notes,done,list_id FROM blocks WHERE inbox_id=? AND user_id=? AND deleted_at IS NULL').get(id,uid);
    if(linked && (linked.title !== title.trim() || linked.notes !== values[2] || linked.done !== done || linked.list_id !== listId)) {
      db.prepare('UPDATE blocks SET title=?,notes=?,done=?,list_id=?,version=version+1 WHERE id=?').run(title.trim(),values[2],done,listId,linked.id);
    }
    return taskWithSchedule(db.prepare('SELECT * FROM inbox WHERE id=?').get(id));
  });
}
export function mountPlanning(app,auth) {
  app.get('/api/inbox',auth,(req,res)=>res.json(db.prepare('SELECT * FROM inbox WHERE user_id=? AND deleted_at IS NULL ORDER BY priority DESC,id DESC').all(req.user.uid).map(taskWithSchedule)));
  const save=(req,res)=> {
    try {
      const task=saveTask(req.user.uid, req.params.id == null ? null : Number(req.params.id),req.body || {},{allowPastReminder:!!req.offlineReplay});
      if(!task) return res.status(404).json({error:'任务不存在'});
      res.json({ok:true,id:task.id,task});
    } catch(e) { res.status(400).json({error:e.message}); }
  };
  app.post('/api/inbox',auth,save);
  app.patch('/api/inbox/:id',auth,save);

  // 删除 = 软删，进回收站；排期块跟着一起走，还原时一起回来。
  app.delete('/api/inbox/:id',auth,(req,res)=> {
    const at=new Date().toISOString();
    const changes=transaction(()=> {
      const r=db.prepare('UPDATE inbox SET deleted_at=?,version=version+1 WHERE id=? AND user_id=? AND deleted_at IS NULL').run(at,req.params.id,req.user.uid);
      if(r.changes) db.prepare('UPDATE blocks SET deleted_at=?,version=version+1 WHERE inbox_id=? AND user_id=? AND deleted_at IS NULL').run(at,req.params.id,req.user.uid);
      return r.changes;
    });
    res.status(changes?200:404).json(changes?{ok:true}:{error:'任务不存在'});
  });

  // ---------- 回收站 ----------
  // 只收「任务」和「独立时间块」；挂在任务下的排期块跟着任务走，不单独露脸，
  // 否则同一个任务会在回收站里出现两次。
  app.get('/api/trash',auth,(req,res)=> {
    const uid=req.user.uid;
    const tasks=db.prepare(`SELECT id,title,deleted_at,done,priority,list_id,due_date,due_time FROM inbox
      WHERE user_id=? AND deleted_at IS NOT NULL`).all(uid).map(t=>({kind:'task',...t}));
    const blocks=db.prepare(`SELECT id,title,deleted_at,date,start_min,end_min FROM blocks
      WHERE user_id=? AND deleted_at IS NOT NULL AND inbox_id IS NULL`).all(uid).map(b=>({kind:'block',...b}));
    const items=[...tasks,...blocks].sort((a,b)=>a.deleted_at<b.deleted_at?1:-1);
    res.json({items});
  });
  app.post('/api/trash/:kind/:id/restore',auth,(req,res)=> {
    const {kind,id}=req.params, uid=req.user.uid;
    if(kind==='task') {
      const changes=transaction(()=> {
        const r=db.prepare('UPDATE inbox SET deleted_at=NULL,version=version+1 WHERE id=? AND user_id=? AND deleted_at IS NOT NULL').run(id,uid);
        if(r.changes) db.prepare('UPDATE blocks SET deleted_at=NULL,version=version+1 WHERE inbox_id=? AND user_id=?').run(id,uid);
        return r.changes;
      });
      return res.status(changes?200:404).json(changes?{ok:true}:{error:'任务不存在'});
    }
    if(kind==='block') {
      const r=db.prepare('UPDATE blocks SET deleted_at=NULL,version=version+1 WHERE id=? AND user_id=? AND inbox_id IS NULL AND deleted_at IS NOT NULL').run(id,uid);
      return res.status(r.changes?200:404).json(r.changes?{ok:true}:{error:'时间块不存在'});
    }
    res.status(400).json({error:'类型不对'});
  });
  app.delete('/api/trash/:kind/:id',auth,(req,res)=> {
    const {kind,id}=req.params, uid=req.user.uid;
    let changes;
    if(kind==='task') changes=transaction(()=> {
      const r=db.prepare('DELETE FROM inbox WHERE id=? AND user_id=? AND deleted_at IS NOT NULL').run(id,uid);
      if(r.changes) db.prepare('DELETE FROM blocks WHERE inbox_id=? AND user_id=?').run(id,uid);
      return r.changes;
    });
    else if(kind==='block') changes=db.prepare('DELETE FROM blocks WHERE id=? AND user_id=? AND inbox_id IS NULL AND deleted_at IS NOT NULL').run(id,uid).changes;
    else return res.status(400).json({error:'类型不对'});
    res.status(changes?200:404).json(changes?{ok:true}:{error:'不存在'});
  });
  // 清空回收站：只碰已软删的行，正常数据一行不动。
  app.delete('/api/trash',auth,(req,res)=> {
    const uid=req.user.uid;
    const r=transaction(()=> {
      const blocks=db.prepare('DELETE FROM blocks WHERE user_id=? AND deleted_at IS NOT NULL').run(uid).changes;
      const tasks=db.prepare('DELETE FROM inbox WHERE user_id=? AND deleted_at IS NOT NULL').run(uid).changes;
      return {blocks,tasks};
    });
    res.json({ok:true,...r});
  });

  // ---------- 已完成 ----------
  // 内容按 done=1 算出来，不落 list_id；超过 3 天由 retention.js 真删。
  app.get('/api/done',auth,(req,res)=> {
    const rows=db.prepare(`SELECT * FROM inbox WHERE user_id=? AND done=1 AND deleted_at IS NULL
      ORDER BY done_at DESC, id DESC`).all(req.user.uid);
    res.json({items:rows.map(t=>({kind:'task',...taskWithSchedule(t)}))});
  });
  // 手动永久删除：不经过回收站。这里本来就已经是「删掉」的意思了，
  // 再往回收站兜一圈等于要删两次；不想删的任务用勾选框收回原清单就行。
  app.delete('/api/done/:id',auth,(req,res)=> {
    const uid=req.user.uid, id=req.params.id;
    const changes=transaction(()=> {
      const r=db.prepare('DELETE FROM inbox WHERE id=? AND user_id=? AND done=1 AND deleted_at IS NULL').run(id,uid);
      if(r.changes) db.prepare('DELETE FROM blocks WHERE inbox_id=? AND user_id=?').run(id,uid);
      return r.changes;
    });
    res.status(changes?200:404).json(changes?{ok:true}:{error:'任务不在已完成里'});
  });
  // 清空已完成：只碰 done=1 且没被软删的，其余一行不动。
  app.delete('/api/done',auth,(req,res)=> {
    const uid=req.user.uid;
    const r=transaction(()=> {
      db.prepare('DELETE FROM blocks WHERE user_id=? AND inbox_id IN (SELECT id FROM inbox WHERE user_id=? AND done=1 AND deleted_at IS NULL)').run(uid,uid);
      return db.prepare('DELETE FROM inbox WHERE user_id=? AND done=1 AND deleted_at IS NULL').run(uid).changes;
    });
    res.json({ok:true,tasks:r});
  });

  // 排期块的编辑/删除都回落到它挂着的任务上，任务本身留着。
  app.patch('/api/blocks/:id',auth,(req,res,next)=> {
    const b=db.prepare('SELECT * FROM blocks WHERE id=? AND user_id=? AND deleted_at IS NULL').get(req.params.id,req.user.uid);
    if(!b?.inbox_id) return next();
    try {
      saveTask(req.user.uid,b.inbox_id,{...req.body,schedule:{date:req.body.date??b.date,start_min:req.body.start_min??b.start_min,end_min:req.body.end_min??b.end_min}});
      if(typeof req.body.color === 'string' && req.body.color !== b.color) db.prepare('UPDATE blocks SET color=?,version=version+1 WHERE id=? AND user_id=?').run(req.body.color,b.id,req.user.uid);
      res.json({ok:true});
    }catch(e){res.status(400).json({error:e.message});}
  });
  app.delete('/api/blocks/:id',auth,(req,res,next)=> {
    const b=db.prepare('SELECT * FROM blocks WHERE id=? AND user_id=? AND deleted_at IS NULL').get(req.params.id,req.user.uid);
    if(!b?.inbox_id) return next();
    // 删排期=取消安排，不是删任务：任务还在收件箱/清单里等着重新排。
    try { saveTask(req.user.uid,b.inbox_id,{schedule:null}); res.json({ok:true}); }
    catch(e){res.status(400).json({error:e.message});}
  });
}
