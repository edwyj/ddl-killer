import express from 'express';
import {mountEmailAccount} from './email-account.js';
import bcrypt from 'bcryptjs';
import { auth, mountSecurity, securityHeaders, limit, validPassword, passwordError, asyncRoute } from './security.js';
import {mountOfflineSync} from './offline-sync.js';
import svgCaptcha from 'svg-captcha';
import { randomUUID } from 'node:crypto';
import { db } from './db.js';
import { mountPlanning, taskWithSchedule } from './task-planning.js';
import { mountReminders } from './reminders.js';
import { createUserWithDefaultLists } from './default-lists.js';
import { getUserSchedule, getDayClasses, currentWeek } from './schedule.js';
import { mountMcpManagement } from './mcp-management.js';
import { mountMcpInternal } from './mcp-internal.js';
import {mountMcpOAuth} from './mcp-oauth.js';
import {mountAiSettings} from './ai-settings.js';
import {mountAiSessions} from './ai-sessions.js';
import {mountAiSpeech} from './ai-speech.js';
import {mountAiInvites} from './ai-invites.js';
import {mountCommunity} from './community.js';
import {mountBetaBoundary} from './beta.js';
import {mountBetaDownloads} from './beta-download.js';



export function createApp(options = {}) {
  if (process.env.AI_FEATURE_ENABLED === 'true') {
    if (!process.env.AI_KEY_ENCRYPTION_KEYS) {
      throw new Error('AI_KEY_ENCRYPTION_KEYS is required when AI_FEATURE_ENABLED=true');
    }
    if (process.env.AI_HOSTED_ENABLED === 'true' && !process.env.AI_HOSTED_DEEPSEEK_KEY) {
      throw new Error('AI_HOSTED_DEEPSEEK_KEY is required when hosted AI is enabled');
    }
  }
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // API is reachable only through the local Caddy proxy.
  app.use(securityHeaders);
  mountBetaBoundary(app);
  app.set('etag', false); // 关 ETag,避免 API 响应被缓存命中返回 304 空 body
  app.use((req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });
  mountBetaDownloads(app,auth,limit);
  mountAiSpeech(app, options.speech);
  mountCommunity(app,auth,limit);
  app.use(express.json({ limit: '2mb' })); // 头像以 base64 data URI 传输，默认 100kb 不够
  app.use((req,res,next)=>{
    if (req.body && (typeof req.body!=='object' || Array.isArray(req.body))) return res.status(400).json({error:'请求应为 JSON 对象'});
    const limits={title:300,name:100,notes:10000,color:32,emoji:32,source:64};
    for(const [key,max] of Object.entries(limits)) {
      const value=req.body?.[key];
      if(value!==undefined && value!==null && (typeof value!=='string'||value.length>max))return res.status(400).json({error:`${key} 格式不正确或过长`});
    }
    next();
  });

  // 请求日志(排查:看后端到底收到哪些 /api 请求)
  app.use((req, res, next) => {
    res.on('finish', () => {
      console.log(`[req] ${req.method} ${req.path} -> ${res.statusCode}`);
    });
    next();
  });


  mountOfflineSync(app,auth);
  mountSecurity(app);
  mountMcpManagement(app);
  mountMcpInternal(app);
  mountMcpOAuth(app);
  mountAiSettings(app, options.ai);
  mountAiInvites(app, auth, limit);
  mountAiSessions(app, options.ai);
  app.use('/api/auth/captcha', limit('captcha', 60));
  app.use('/api/auth/register', limit('register', 12));
  app.use('/api/auth/setup', limit('setup', 5));

  // ---------- 账号 ----------
  // 首次初始化(users 表为空时):创建第一个账号
  app.post('/api/auth/setup', asyncRoute(async (req, res) => {
    const { username, password } = req.body || {};
    const { c } = db.prepare('SELECT COUNT(*) c FROM users').get();
    if (c > 0) return res.status(403).json({ error: '已初始化' });
    if (typeof username !== 'string' || !/^[A-Za-z0-9_]{2,32}$/.test(username) || !validPassword(password))
      return res.status(400).json({ error: passwordError(password) || '请检查账号填写是否正确' });
    const hash = await bcrypt.hash(password, 10);
    if (db.prepare('SELECT count(*) c FROM users').get().c > 0) return res.status(403).json({error:'已初始化'});
    createUserWithDefaultLists(username, hash);
    res.json({ ok: true });
  }));

  // 图形验证码：内存存储 id -> { code, exp }，进程重启即失效（单实例部署够用）
  const captchas = new Map();
  const CAPTCHA_TTL = 5 * 60 * 1000;

  app.get('/api/auth/captcha', (req, res) => {
    const now = Date.now();
    for (const [k, v] of captchas) if (v.exp < now) captchas.delete(k); // 惰性清理
    // 本接口无鉴权：先清过期再限流，防止刷接口把 Map 撑爆(单条 svg ~9KB)
    if (captchas.size > 5000) return res.status(429).json({ error: '请求过于频繁，请稍后再试' });
    const cap = svgCaptcha.create({ size: 4, noise: 2, color: true, background: '#f2f4f7', ignoreChars: '0o1il' });
    const id = randomUUID();
    captchas.set(id, { code: cap.text.toLowerCase(), exp: now + CAPTCHA_TTL });
    res.json({ id, svg: cap.data });
  });

  function verifyCaptcha(id, code) {
    const e = captchas.get(id);
    if (!e) return false;
    captchas.delete(id);            // 一次性，用后即焚
    if (e.exp < Date.now()) return false;
    return String(code || '').toLowerCase().trim() === e.code;
  }

  mountEmailAccount(app, verifyCaptcha, options.email);

  app.get('/api/me', auth, (req, res) => {
    const u = db.prepare('SELECT username, nickname, avatar FROM users WHERE id=?').get(req.user.uid);
    res.json({
      username: (u && u.username) || req.user.username,
      nickname: (u && u.nickname) || '',
      avatar: (u && u.avatar) || '',
      has_schedule: !!getUserSchedule(req.user.uid),
    });
  });

  // 改资料：nickname(≤24) / avatar(spec 字符串)，两者都可选
  app.patch('/api/me', auth, (req, res) => {
    const body = req.body || {};
    const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
    const u = db.prepare('SELECT nickname, avatar FROM users WHERE id=?').get(req.user.uid);
    if (!u) return res.status(404).json({ error: '用户不存在' });

    let nickname = u.nickname || '';
    let avatar = u.avatar || '';

    if (has('nickname')) {
      const n = body.nickname;
      if (typeof n !== 'string' || n.length > 24)
        return res.status(400).json({ error: '昵称需为不超过 24 字的字符串' });
      nickname = n;
    }
    if (has('avatar')) {
      const a = body.avatar;
      if (typeof a !== 'string') return res.status(400).json({ error: '头像格式不对' });
      if (a.length > 500000) return res.status(400).json({ error: '头像过大' });
      // 空串=用默认渲染；否则必须是 preset: 或 data:image/
      if (a !== '' && !a.startsWith('preset:') && !a.startsWith('data:image/'))
        return res.status(400).json({ error: '头像格式不对' });
      avatar = a;
    }

    db.prepare('UPDATE users SET nickname=?, avatar=? WHERE id=?').run(nickname, avatar, req.user.uid);
    res.json({ ok: true });
  });

  // 「我的」页统计：清单数 / 未完成待办 / 已完成 / 课程数(全为整数)
  app.get('/api/stats', auth, (req, res) => {
    const uid = req.user.uid;
    const count = (sql) => Number(db.prepare(sql).get(uid).c);
    const sched = getUserSchedule(uid);
    res.json({
      lists: count('SELECT COUNT(*) c FROM lists WHERE user_id=? AND system IS NULL'),
      todos: count('SELECT COUNT(*) c FROM blocks WHERE user_id=? AND inbox_id IS NULL AND done=0 AND deleted_at IS NULL') +
             count('SELECT COUNT(*) c FROM inbox WHERE user_id=? AND done=0 AND deleted_at IS NULL'),
      done: count('SELECT COUNT(*) c FROM blocks WHERE user_id=? AND inbox_id IS NULL AND done=1 AND deleted_at IS NULL') +
            count('SELECT COUNT(*) c FROM inbox WHERE user_id=? AND done=1 AND deleted_at IS NULL'),
      courses: sched && Array.isArray(sched.courses) ? sched.courses.length : 0,
    });
  });

  // ---------- 课表（per-user）----------
  app.get('/api/schedule', auth, (req, res) => {
    const s = getUserSchedule(req.user.uid);
    if (!s) return res.status(404).json({ error: '无课表' });
    res.json(s);
  });

  app.put('/api/schedule', auth, (req, res) => {
    const sched = req.body || {}; // body 即课表对象本身
    if (!sched || !(sched.semester_start || Array.isArray(sched.courses)))
      return res.status(400).json({ error: '课表格式不对' });
    db.prepare('INSERT INTO schedules (user_id, json) VALUES (?,?) ON CONFLICT(user_id) DO UPDATE SET json=excluded.json, updated_at=datetime(\'now\')')
      .run(req.user.uid, JSON.stringify(sched));
    res.json({ ok: true });
  });

  // ---------- 每日时间轴 ----------
  app.get('/api/day', auth, (req, res) => {
    const date = req.query.date;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date || ''))
      return res.status(400).json({ error: 'date 需为 YYYY-MM-DD' });
    const schedule = getUserSchedule(req.user.uid);
    const classes = schedule ? getDayClasses(schedule, date) : [];
    const blocks = db
      .prepare('SELECT * FROM blocks WHERE user_id=? AND date=? AND deleted_at IS NULL ORDER BY start_min')
      .all(req.user.uid, date)
      .map((b) => ({ ...b, type: 'task' }));
    const timeline = [...classes, ...blocks].sort(
      (a, b) => a.start_min - b.start_min || a.end_min - b.end_min
    );
    res.json({ date, timeline, classes, blocks });
  });

  // ---------- 连续 N 天时间轴(周视图/范围视图用) ----------
  function fmtDate(d) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${dd}`;
  }

  function weekdayOf(dateStr) {
    const g = new Date(dateStr + 'T00:00:00').getDay();
    return g === 0 ? 7 : g; // 周一=1
  }

  function buildDays(uid, startStr, count) {
    const s = new Date(startStr + 'T00:00:00');
    const schedule = getUserSchedule(uid);
    const days = [];
    for (let i = 0; i < count; i++) {
      const d = new Date(s);
      d.setDate(s.getDate() + i);
      const ds = fmtDate(d);
      const classes = schedule ? getDayClasses(schedule, ds) : [];
      const blocks = db
        .prepare('SELECT * FROM blocks WHERE user_id=? AND date=? AND deleted_at IS NULL ORDER BY start_min')
        .all(uid, ds)
        .map((b) => ({ ...b, type: 'task' }));
      const timeline = [...classes, ...blocks].sort(
        (a, b) => a.start_min - b.start_min || a.end_min - b.end_min
      );
      days.push({ date: ds, weekday: weekdayOf(ds), timeline, classes, blocks });
    }
    return days;
  }

  // 任意连续 N 天(范围视图):?start=YYYY-MM-DD&count=N
  app.get('/api/days', auth, (req, res) => {
    const start = req.query.start;
    const count = Math.min(Math.max(parseInt(req.query.count) || 7, 1), 31);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start || ''))
      return res.status(400).json({ error: 'start 需为 YYYY-MM-DD' });
    if (isNaN(new Date(start + 'T00:00:00')))
      return res.status(400).json({ error: '日期无效' });
    const days = buildDays(req.user.uid, start, count);
    const weekNum = currentWeek(getUserSchedule(req.user.uid), start);
    res.json({ start, count, weekNum, days });
  });

  // 整周(周视图):?start 为周内任意一天，返回该周周一~周日 7 天
  app.get('/api/week', auth, (req, res) => {
    const start = req.query.start;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start || ''))
      return res.status(400).json({ error: 'start 需为 YYYY-MM-DD' });
    const s = new Date(start + 'T00:00:00');
    if (isNaN(s)) return res.status(400).json({ error: '日期无效' });
    const iso = s.getDay() === 0 ? 7 : s.getDay();
    const monday = new Date(s);
    monday.setDate(s.getDate() - (iso - 1));
    const days = buildDays(req.user.uid, fmtDate(monday), 7);
    const weekNum = currentWeek(getUserSchedule(req.user.uid), fmtDate(monday));
    res.json({ start, monday: fmtDate(monday), weekNum, days });
  });

  mountPlanning(app, auth);
  mountReminders(app, auth);

  // ---------- 任务时间块 ----------
  app.post('/api/blocks', auth, (req, res) => {
    const { date, start_min, end_min, title, color, notes, source } = req.body || {};
    if (!date || typeof start_min !== 'number' || typeof end_min !== 'number' || !title)
      return res.status(400).json({ error: '缺字段' });
    if (start_min < 0 || end_min > 1440 || start_min >= end_min)
      return res.status(400).json({ error: '时间范围不对' });
    const r = db
      .prepare('INSERT INTO blocks (user_id,date,start_min,end_min,title,color,notes,source) VALUES (?,?,?,?,?,?,?,?)')
      .run(req.user.uid, date, start_min, end_min, title, color || '', notes || '', source || 'manual');
    res.json({ id: Number(r.lastInsertRowid) });
  });

  app.patch('/api/blocks/:id', auth, (req, res) => {
    const row = db.prepare('SELECT * FROM blocks WHERE id=? AND user_id=?').get(req.params.id, req.user.uid);
    if (!row) return res.status(404).json({ error: '不存在' });
    const { start_min, end_min, title, color, done, notes } = req.body || {};
    const newDone = done === undefined ? row.done : (done ? 1 : 0);
    const next=[start_min ?? row.start_min,end_min ?? row.end_min,title ?? row.title,color ?? row.color,newDone,notes ?? row.notes];
    const keys=['start_min','end_min','title','color','done','notes'];
    if(keys.some((key,index)=>row[key]!==next[index])) db.prepare('UPDATE blocks SET start_min=?, end_min=?, title=?, color=?, done=?, notes=?,version=version+1 WHERE id=?')
      .run(...next,req.params.id);
    res.json({ ok: true });
  });

  // 走到这里说明是不属于任何任务的独立时间块(任务排期在 task-planning.js 里被截走了)。
  // 同样是软删，进回收站 —— 否则日历上删错一个块就再也找不回来。
  app.delete('/api/blocks/:id', auth, (req, res) => {
    const r = db.prepare('UPDATE blocks SET deleted_at=?,version=version+1 WHERE id=? AND user_id=? AND deleted_at IS NULL')
      .run(new Date().toISOString(), req.params.id, req.user.uid);
    if (r.changes === 0) return res.status(404).json({ error: '不存在' });
    res.json({ ok: true });
  });

  // ---------- 清单(lists) ----------
  app.get('/api/lists', auth, (req, res) => {
    const lists = db.prepare('SELECT * FROM lists WHERE user_id=? ORDER BY id').all(req.user.uid);
    const numBlocks = (id) =>
      db.prepare('SELECT COUNT(*) c FROM blocks WHERE user_id=? AND inbox_id IS NULL AND list_id=? AND done=0 AND deleted_at IS NULL').get(req.user.uid, id).c;
    const numInbox = (id) =>
      db.prepare('SELECT COUNT(*) c FROM inbox WHERE user_id=? AND list_id=? AND done=0 AND deleted_at IS NULL').get(req.user.uid, id).c;
    // 回收站/已完成的成员不靠 list_id，得单独数，否则角标永远是 0。
    const c = (sql) => Number(db.prepare(sql).get(req.user.uid).c);
    const trashCount = c('SELECT COUNT(*) c FROM inbox WHERE user_id=? AND deleted_at IS NOT NULL') +
                       c('SELECT COUNT(*) c FROM blocks WHERE user_id=? AND deleted_at IS NOT NULL AND inbox_id IS NULL');
    const doneCount = c('SELECT COUNT(*) c FROM inbox WHERE user_id=? AND done=1 AND deleted_at IS NULL');
    const data = lists.map((l) => ({
      ...l,
      task_count: l.system === 'trash' ? trashCount
                : l.system === 'done' ? doneCount
                : numBlocks(l.id) + numInbox(l.id),
    }));
    res.json(data);
  });

  app.post('/api/lists', auth, (req, res) => {
    const { name, color, emoji } = req.body || {};
    if (!name || !name.trim()) return res.status(400).json({ error: '缺 name' });
    const r = db.prepare('INSERT INTO lists (user_id,name,color,emoji) VALUES (?,?,?,?)')
      .run(req.user.uid, name.trim(), color || '', emoji || '');
    res.json({ id: Number(r.lastInsertRowid) });
  });

  app.patch('/api/lists/:id', auth, (req, res) => {
    const row = db.prepare('SELECT * FROM lists WHERE id=? AND user_id=?').get(req.params.id, req.user.uid);
    if (!row) return res.status(404).json({ error: '不存在' });
    const { name, color, emoji } = req.body || {};
    db.prepare('UPDATE lists SET name=?, color=?, emoji=? WHERE id=?')
      .run(name ?? row.name, color ?? row.color, emoji ?? row.emoji, req.params.id);
    res.json({ ok: true });
  });

  app.delete('/api/lists/:id', auth, (req, res) => {
    const row = db.prepare('SELECT id,system FROM lists WHERE id=? AND user_id=?').get(req.params.id, req.user.uid);
    if (!row) return res.status(404).json({ error: '不存在' });
    // 系统清单是功能入口，删掉就再也长不回来(靠标记认，不靠名字)。
    // 嫌名字不好听可以改名，但别删。
    if (row.system) return res.status(400).json({ error: '系统清单不能删除' });
    db.prepare('DELETE FROM lists WHERE id=?').run(req.params.id);
    db.prepare('UPDATE blocks SET list_id=NULL,version=version+1 WHERE list_id=? AND user_id=?').run(req.params.id,req.user.uid);
    db.prepare('UPDATE inbox SET list_id=NULL,version=version+1 WHERE list_id=? AND user_id=?').run(req.params.id,req.user.uid);
    res.json({ ok: true });
  });

  // 清单详情：该清单下所有任务(时间块 + 收件箱)
  app.get('/api/lists/:id/tasks', auth, (req, res) => {
    const row = db.prepare('SELECT * FROM lists WHERE id=? AND user_id=?').get(req.params.id, req.user.uid);
    if (!row) return res.status(404).json({ error: '不存在' });
    const blocks = db.prepare('SELECT * FROM blocks WHERE user_id=? AND inbox_id IS NULL AND list_id=? AND deleted_at IS NULL ORDER BY date').all(req.user.uid, req.params.id);
    const inbox = db.prepare('SELECT * FROM inbox WHERE user_id=? AND list_id=? AND deleted_at IS NULL ORDER BY done,id DESC').all(req.user.uid, req.params.id);
    res.json({ list: row, blocks, inbox: inbox.map(taskWithSchedule) });
  });

  app.get('/api/health', (req, res) => res.json({ ok: true }));

  app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    console.error('API request failed', error.type || error.name);
    res.status(error.status === 413 ? 413 : error instanceof SyntaxError ? 400 : 500).json({error: error.status === 413 ? '请求数据过大' : error instanceof SyntaxError ? '请求格式不正确' : '服务暂不可用，请稍后重试'});
  });
  return app;
}
