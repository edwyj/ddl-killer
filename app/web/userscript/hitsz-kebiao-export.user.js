// ==UserScript==
// @name         哈工深 课表导出 → DDL Killer
// @namespace    https://ddlkiller.com/
// @version      1.0.1
// @description  在哈工大（深圳）本研教学管理与服务平台任意已登录页面，一键导出整学期课表为 schedule.json，供 DDL Killer「导入课表」使用。
// @author       Andy
// @match        https://hitsz.edu.cn/*
// @match        https://*.hitsz.edu.cn/*
// @grant        none
// @downloadURL  https://ddlkiller.com/userscript/hitsz-kebiao-export.user.js
// @updateURL    https://ddlkiller.com/userscript/hitsz-kebiao-export.user.js
// @run-at       document-idle
// ==/UserScript==
//
// ─────────────────────────────────────────────────────────────────────────
// 安全说明（重要）
//   本脚本全程【只读】，且完全在你的浏览器里运行：
//     · 不索取、不读取、不外传你的账号和密码
//     · 不保存 cookie / token，不使用任何外部服务器
//     · 只向教务系统自己的课表查询接口发 POST，等价于你在页面上翻看课表
//   它产出的是一个 schedule.json 文件，下载到你自己电脑上，由你自行决定是否导入。
// ─────────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  // ───────────── 配置 ─────────────
  const VERSION = '1.0.1';   // 与文件头的 @version 保持一致

  // 接口路径与教务平台自身完全一致：平台代码是 var baseUrl="/" 再拼路径，
  // 即【站点根绝对路径】。v1.0.0 曾写成不带斜杠的相对路径，fetch 会按「当前
  // 页面所在目录」解析——在 /authentication/main 下点导出就打到
  // /authentication/component/…，必然 404。平台自己在任何页面都是按根路径调的，
  // 所以根绝对路径在任何已登录页面都成立。
  const URL_XNXQ = '/component/querydangqianxnxq';   // 当前学年学期
  const URL_ZC = '/component/querydangqianzc';       // 当前第几周
  const URL_ALL = '/xszykb/queryxszykbzong';         // 整学期课表（一次拿全，不用逐周抓）
  const URL_KBJG = '/component/queryKbjg';           // 节次结构（大节 ↔ 小节、上下课时间）
  const URL_RLZC = '/component/queryRlZcSj';         // 某周 7 天的日期（用来定位开学第一天）
  // 导出给离线测试核对路径形态（tool/hitsz_kebiao_export_test.mjs）。
  const ENDPOINTS = { xnxq: URL_XNXQ, zc: URL_ZC, all: URL_ALL, kbjg: URL_KBJG, rlzc: URL_RLZC };

  // 拿不到教务作息时的兜底（仅影响时间轴刻度，不影响课在星期几）
  const FALLBACK_PERIOD_TIMES = {
    '1': ['08:30', '10:05'], '2': ['10:25', '12:00'],
    '3': ['14:00', '15:35'], '4': ['15:55', '17:30'],
    '5': ['19:00', '20:35'], '6': ['20:45', '22:20'],
  };

  // ───────────── 纯解析函数（可离线单测） ─────────────

  /** 去掉全角/不可见字符，逐行 trim */
  function splitLines(text) {
    return String(text == null ? '' : text)
      .replace(/\r/g, '')
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  }

  /** 是「只由方括号组成」的行吗：[A]、[A][B]、[A],[B] 都算 */
  function isBracketOnly(line) {
    return /^(?:\[[^\]]*\])+(?:\s*,\s*(?:\[[^\]]*\])+)*\s*$/.test(line);
  }

  /** 取出一行里的所有方括号内容 → ['1-5,7-13周', 'T3201'] */
  function brackets(line) {
    const out = [];
    const re = /\[([^\]]*)\]/g;
    let m;
    while ((m = re.exec(line)) !== null) out.push(m[1].trim());
    return out;
  }

  /**
   * '1-5,7-13周' → {weeks:[1..5,7..13], parity:''}
   * '1-16周单' / '1-16周(单)' → {weeks:[1,3,5...], parity:'单'}
   * 把「单/双」直接展开成具体的周，App 那边不用再懂这个词。
   */
  function parseWeeks(text) {
    const s = String(text == null ? '' : text).replace(/第/g, '');
    let parity = '';
    if (/单/.test(s)) parity = '单';
    else if (/双/.test(s)) parity = '双';

    const out = [];
    for (const raw of s.split(/[,，]/)) {
      const part = raw.trim();
      if (!part) continue;
      let m = part.match(/^(\d+)\s*[-－~～]\s*(\d+)/);
      if (m) {
        const a = Number(m[1]);
        const b = Number(m[2]);
        for (let i = Math.min(a, b); i <= Math.max(a, b); i++) out.push(i);
        continue;
      }
      m = part.match(/^(\d+)/);
      if (m) out.push(Number(m[1]));
    }
    let weeks = [...new Set(out)].sort((a, b) => a - b);
    if (parity === '单') weeks = weeks.filter((w) => w % 2 === 1);
    if (parity === '双') weeks = weeks.filter((w) => w % 2 === 0);
    return { weeks, parity };
  }

  /** '[3-4节]' 或 '第3-4节' → [3,4]；'[9节]' → [9] */
  function parsePeriods(text) {
    const m = String(text == null ? '' : text).match(/(\d+)\s*[-－~～]\s*(\d+)\s*节/);
    if (m) {
      const a = Number(m[1]);
      const b = Number(m[2]);
      const out = [];
      for (let i = Math.min(a, b); i <= Math.max(a, b); i++) out.push(i);
      return out;
    }
    const one = String(text == null ? '' : text).match(/(\d+)\s*节/);
    return one ? [Number(one[1])] : [];
  }

  /** KEY（大致形如 xq1_jc3）→ {weekday, block}，拿不到返回 null */
  function parseKey(key) {
    const m = String(key == null ? '' : key).match(/xq\s*(\d)\s*_?\s*jc\s*(\d+)/i);
    if (!m) return null;
    return { weekday: Number(m[1]), block: Number(m[2]) };
  }

  /** 课程名的「同一门课」归一形式：去掉末尾的实验项目名，保留分组 */
  function canonicalName(name) {
    const lines = splitLines(name);
    if (!lines.length) return '';
    const last = lines[lines.length - 1].replace(/\[[^\]]*\]\s*$/, '').trim();
    lines[lines.length - 1] = last || lines[lines.length - 1];
    return lines.join(' ').trim();
  }

  /** 从课程名里抽出分组（阿拉伯数字和中文数字都出现过：第20组 / 第一组） */
  function extractGroup(name) {
    const m = String(name || '').match(/第\s*[0-9一二三四五六七八九十百]+\s*组/);
    return m ? m[0].replace(/\s+/g, '') : '';
  }

  /**
   * 解析一条课表数据的 SKSJ 文本 → {name, teacher, room, weeks, periods, parity}
   *
   * 实测格式（同一个格子里的多行）：
   *   概率论与数理统计            ← 课程名，可能不止一行（体育C / 定向越野）
   *   [王勇]                      ← 教师，单独一行、且出现在周次行之前
   *   [1-5,7-13周][T3201]         ← 周次和教室常常同一行；合并过的会有多段用逗号相连
   *   第1-2节                     ← 节次，也可能写成 [3-4节] 跟周次同行
   *
   * 判定规则：第一行方括号之前的是课程名；周次行之前单独成行的方括号是教师；
   * 周次行及其之后的非周次、非节次方括号是教室。
   */
  function parseSKSJ(sksj) {
    const lines = splitLines(sksj);
    const out = { name: '', teacher: '', room: '', weeks: [], periods: [], parity: '' };
    if (!lines.length) return out;

    let i = 0;
    const nameLines = [];
    for (; i < lines.length; i++) {
      // 把方括号整段挖掉后什么都不剩 ⇒ 这条是元信息行，名字到此为止
      // （实验课的课名末尾自带 [实验项目名]，那种行挖掉方括号还有字，算名字）
      const outside = lines[i].replace(/\[[^\]]*\]/g, '').replace(/[\s,，]/g, '');
      if (!outside) break;
      if (/^第?\d+\s*[-－~～]?\s*\d*\s*节$/.test(lines[i])) break;   // 节次行
      nameLines.push(lines[i]);
    }
    out.name = nameLines.join(' ').trim();

    const rooms = [];
    const weeks = [];
    let parity = '';
    let periods = [];

    for (; i < lines.length; i++) {
      const line = lines[i];
      if (!isBracketOnly(line)) {
        // 非方括号行：只可能是节次行
        const p = parsePeriods(line);
        if (p.length) periods = periods.concat(p);
        continue;
      }
      for (const inner of brackets(line)) {
        if (/周/.test(inner)) {
          const w = parseWeeks(inner);
          weeks.push(...w.weeks);
          if (w.parity) parity = w.parity;
        } else if (/\d+\s*节/.test(inner)) {
          periods = periods.concat(parsePeriods(inner));
        } else if (!weeks.length && !out.teacher && inner) {
          // 还没见到周次行 ⇒ 这是教师
          out.teacher = inner;
        } else if (inner) {
          rooms.push(inner);
        }
      }
    }

    out.weeks = [...new Set(weeks)].sort((a, b) => a - b);
    out.periods = [...new Set(periods)].sort((a, b) => a - b);
    out.parity = parity;
    // 教室可能重复（合并后的多段周次各写了一次同样的教室）
    out.room = [...new Set(rooms)].join('/');
    return out;
  }

  /**
   * 整学期课表原始数据 → 归一化的时段列表
   * items: [{KEY, SKSJ, KSJC, JSJC, JASMC, ...}]
   */
  function parseItems(items) {
    const out = [];
    const seen = new Set();
    for (const item of (Array.isArray(items) ? items : [])) {
      if (!item || typeof item !== 'object') continue;
      const sksj = item.SKSJ || item.SKSJ_EN || '';
      const parsed = parseSKSJ(sksj);

      const key = parseKey(item.KEY);
      let weekday = key ? key.weekday : 0;
      if (!weekday) {
        const alt = Number(item.XQJ);
        if (alt >= 1 && alt <= 7) weekday = alt;
      }
      if (!(weekday >= 1 && weekday <= 7)) continue;   // 定位不了星期几，跳过

      let periods = parsed.periods;
      if (!periods.length) {
        const a = Number(item.KSJC);
        const b = Number(item.JSJC);
        if (a > 0 && b >= a) {
          for (let n = a; n <= b; n++) periods.push(n);
        }
      }
      let block = key ? key.block : 0;
      if (!block && periods.length) block = Math.ceil(periods[0] / 2);
      if (!periods.length && block) periods = [block * 2 - 1, block * 2];

      // 教室：SKSJ 里没写就用结构化字段兜底
      const room = parsed.room || String(item.JASMC || '').trim();

      const name = parsed.name || canonicalName(item.SKSJ || '');
      if (!name || !periods.length || !parsed.weeks.length) continue;

      const sig = [name, weekday, periods.join(','), parsed.weeks.join(','), room].join('|');
      if (seen.has(sig)) continue;   // 同一门课会因为合并拆成多条，去重
      seen.add(sig);

      out.push({
        name: canonicalName(name),
        teacher: parsed.teacher,
        room,
        weekday,
        periods: periods.slice().sort((a, b) => a - b),
        weeks: parsed.weeks,
        block,
        group: extractGroup(name),
      });
    }
    return out;
  }

  /** 归一化时段列表 → DDL Killer 的 courses[] */
  function groupCourses(sections) {
    const byName = new Map();
    for (const s of sections) {
      let c = byName.get(s.name);
      if (!c) {
        c = { course_id: courseId(s.name), name: s.name, teacher: '', type: '', attr: '', slots: [] };
        byName.set(s.name, c);
      }
      if (s.teacher && c.teacher.indexOf(s.teacher) === -1) {
        c.teacher = c.teacher ? c.teacher + '、' + s.teacher : s.teacher;
      }
      c.slots.push({
        section: c.slots.length + 1,
        group: s.group || '',
        weekday: s.weekday,
        periods: s.periods,
        weeks: s.weeks,
        room: s.room,
      });
    }
    // 课程号：教务没给出稳定课程号，用课名的稳定哈希代替，保证重复导入时 id 不变
    return [...byName.values()].sort((a, b) => cmpStr(a.name, b.name));
  }

  const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

  function courseId(name) {
    let h = 5381;
    const s = String(name == null ? '' : name);
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return 'hitsz-' + h.toString(36);
  }

  /** 教务的节次结构 → {period_times, period_to_block} */
  function buildPeriodTables(kbjgContent, usedBlocks) {
    const period_times = {};
    const period_to_block = {};
    const list = Array.isArray(kbjgContent) ? kbjgContent : [];
    const byBlock = new Map();
    for (const e of list) {
      const dj = Number(e && e.dj);
      if (!(dj > 0)) continue;
      const xj = Number(e && e.xj);
      const rec = byBlock.get(dj) || { lo: Infinity, hi: -Infinity, start: '', end: '' };
      // 大节的开始时间取第一个小节的，结束时间取最后一个小节的
      if (xj > 0) {
        if (xj < rec.lo) { rec.lo = xj; rec.start = hhmm(e.kssj) || rec.start; }
        if (xj > rec.hi) { rec.hi = xj; rec.end = hhmm(e.jssj) || rec.end; }
      } else {
        if (!rec.start) rec.start = hhmm(e.kssj);
        if (!rec.end) rec.end = hhmm(e.jssj);
      }
      byBlock.set(dj, rec);
    }
    for (const [dj, rec] of byBlock) {
      if (rec.lo !== Infinity) {
        period_to_block[String(rec.lo)] = dj;
        period_to_block[String(rec.hi)] = dj;
        // 中间的小节也归同一个大节
        for (let n = rec.lo; n <= rec.hi; n++) period_to_block[String(n)] = dj;
      }
      if (rec.start && rec.end) period_times[String(dj)] = [rec.start, rec.end];
    }
    // 教务没覆盖到的作息补齐（只影响时间轴，不影响星期几）
    for (const b of (usedBlocks || [])) {
      if (!period_times[String(b)]) {
        const t = FALLBACK_PERIOD_TIMES[String(b)];
        if (t) period_times[String(b)] = t;
      }
      if (!period_to_block[String(b * 2 - 1)]) period_to_block[String(b * 2 - 1)] = b;
      if (!period_to_block[String(b * 2)]) period_to_block[String(b * 2)] = b;
    }
    return { period_times, period_to_block };
  }

  function hhmm(raw) {
    const m = String(raw == null ? '' : raw).match(/(\d{1,2}):(\d{2})/);
    return m ? String(Number(m[1])).padStart(2, '0') + ':' + m[2] : '';
  }

  /** 年月日都在合理范围内才算数，避免把流水号之类的东西当成日期 */
  function validYmd(y, m, d) {
    return Number(y) >= 2000 && Number(y) <= 2100
      && Number(m) >= 1 && Number(m) <= 12
      && Number(d) >= 1 && Number(d) <= 31;
  }

  /** '2026-09-07' / '2026/9/7' / '09-07' / [2026,9,7] → 'YYYY-MM-DD'；认不出返回 '' */
  function normalizeDate(raw, xn) {
    if (raw == null) return '';
    if (Array.isArray(raw) && raw.length >= 3) {
      if (!validYmd(raw[0], raw[1], raw[2])) return '';
      return p4(raw[0]) + '-' + p2(raw[1]) + '-' + p2(raw[2]);
    }
    const s = String(raw).trim();
    let m = s.match(/(\d{4})\D+(\d{1,2})\D+(\d{1,2})/);
    if (m && validYmd(m[1], m[2], m[3])) return p4(m[1]) + '-' + p2(m[2]) + '-' + p2(m[3]);
    // 只有月日时，用学年的年份补上（如 '09-07' + '2026-2027' → '2026-09-07'）
    m = s.match(/^(\d{1,2})\D+(\d{1,2})$/);
    const y = String(xn == null ? '' : xn).match(/\d{4}/);
    if (m && y && validYmd(y[0], m[1], m[2])) return y[0] + '-' + p2(m[1]) + '-' + p2(m[2]);
    return '';
  }

  function p2(n) { return String(Number(n)).padStart(2, '0'); }
  function p4(n) { return String(Number(n)).padStart(4, '0'); }

  /** 某一天所在那一周的周一，返回 'YYYY-MM-DD' */
  function mondayOf(date) {
    const d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    const dow = (d.getDay() + 6) % 7;          // 周一=0
    d.setDate(d.getDate() - dow);
    return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate());
  }

  function shiftDays(ymd, days) {
    const m = String(ymd).match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!m) return '';
    const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
    d.setDate(d.getDate() + days);
    return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate());
  }

  // ───────────── 抓取 ─────────────

  async function post(path, params) {
    const body = new URLSearchParams(params || {});
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
      body,
      credentials: 'same-origin',   // 同源请求，自动带上你当前的登录态
    });
    if (!r.ok) throw new Error(path + ' 请求失败：HTTP ' + r.status + '（当前页面 ' + location.host + '）');
    const text = await r.text();
    const t = text.trim();
    if (t.charAt(0) === '<') throw new Error('SESSION_EXPIRED');   // 被弹回登录页
    try {
      return JSON.parse(t);
    } catch (_) {
      throw new Error(path + ' 返回的不是预期数据（可能登录已过期）');
    }
  }

  /** 学期第一周的周一 —— App 靠它把「第N周」换算成具体日期，缺了会整体错位 */
  async function resolveSemesterStart(xn, xq) {
    // ① 首选：让教务直接说出第 1 周 7 天的日期
    try {
      const res = await post(URL_RLZC, { xn: xn, xq: xq, djz: '1' });
      const content = (res && res.content) || [];
      const monday = content.filter((e) => Number(e && e.xqj) === 1)[0]
        || content[0];
      const d = normalizeDate(monday && monday.rq, xn);
      if (d) return { date: d, source: '教务校历' };
    } catch (_) { /* 落到下一级 */ }

    // ② 次选：用「现在是第几周」倒推
    try {
      const zc = Number(await post(URL_ZC, {}));
      if (zc > 0) {
        const d = shiftDays(mondayOf(new Date()), -(zc - 1) * 7);
        if (d) return { date: d, source: '按当前第 ' + zc + ' 周倒推' };
      }
    } catch (_) { /* 落到下一级 */ }

    return { date: '', source: '' };
  }

  /** 抓完整学期 → 组装成 DDL Killer 的 schedule.json 结构 */
  async function buildSchedule(onProgress) {
    const step = onProgress || function () {};
    step('正在读取当前学期…');

    const xnxq = await post(URL_XNXQ, {});
    const xn = String((xnxq && xnxq.XN) || '').trim();
    const xq = String((xnxq && xnxq.XQ) || '').trim();
    if (!xn || !xq) throw new Error('没读到当前学年学期，请确认已登录教务系统');
    const semester = String((xnxq && xnxq.XNXQ) || (xn + '-' + xq)).trim();

    step('正在读取整学期课表…');
    const raw = await post(URL_ALL, { xn: xn, xq: xq });
    const items = Array.isArray(raw) ? raw
      : (raw && Array.isArray(raw.content)) ? raw.content
      : (raw && Array.isArray(raw.rows)) ? raw.rows
      : [];
    if (!items.length) throw new Error('教务返回的课表是空的（可能本学期还没排课）');

    const sections = parseItems(items);
    if (!sections.length) throw new Error('课表里有数据，但没能识别出上课时间，请把这条信息反馈给我们');

    step('正在读取作息时间…');
    let kbjg = [];
    try {
      const res = await post(URL_KBJG, { xn: xn, xq: xq, pylx: '' });
      kbjg = (res && res.content) || [];
    } catch (_) { /* 拿不到就用兜底作息 */ }

    step('正在定位开学第一周…');
    const start = await resolveSemesterStart(xn, xq);

    const usedBlocks = [...new Set(sections.map((s) => s.block).filter((b) => b > 0))];
    const tables = buildPeriodTables(kbjg, usedBlocks);
    const courses = groupCourses(sections);

    const notes = ['作息时间由教务系统提供。'];
    if (!kbjg.length) notes.push('教务作息接口未返回数据，时间轴按默认作息显示。');
    if (start.date) {
      notes.push('开学第一周：' + start.date + '（' + start.source + '）。');
    } else {
      notes.push('⚠️ 没能自动读到开学第一周，请在导入后手动确认，否则周次会整体错位。');
    }

    return {
      semester: semester,
      semester_start: start.date,
      updated_at: nowStr(),
      period_times: tables.period_times,
      period_to_block: tables.period_to_block,
      time_note: notes.join(''),
      week_source: start.source ? '教务校历' : 'unknown',
      courses: courses,
      no_fixed_time: [],
      _warning: start.date ? '' : 'semester_start_missing',
    };
  }

  function nowStr() {
    const d = new Date();
    return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate())
      + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes());
  }

  // ───────────── 浏览器 UI ─────────────
  //
  // 教务平台是普通 body 文档 + 动态插入的 iframe，页面里存在 0×0 的 about:blank iframe。
  // Tampermonkey 默认往每个 frame 各注一份，谁先跑谁赢的话，按钮可能被建在零尺寸的文档里
  // ——症状正是"装好了却看不到按钮"，而且不报错。所以宿主必须【确定性地】选：
  // 每一层都用同一套规则算出同一个宿主，只有被选中的那一层真正注入。
  function hasRealBody(doc) {
    const b = doc && doc.body;
    return !!b && b.tagName !== 'FRAMESET';
  }

  /** 这个窗口够不够格当宿主：要有真 body，而且真有可见尺寸 */
  function isUsableHost(win) {
    try {
      if (!hasRealBody(win.document)) return false;
      if ((win.innerWidth || 0) < 320 || (win.innerHeight || 0) < 240) return false;
      return true;
    } catch (_) { return false; }   // 跨域，摸不得
  }

  /** 从顶层往下挑唯一宿主：顶层可用就用顶层，否则取面积最大的可用 frame */
  function pickHost(topWin) {
    if (isUsableHost(topWin)) return topWin;
    let best = null;
    let bestArea = -1;
    (function walk(w) {
      let n = 0;
      try { n = w.frames.length; } catch (_) { return; }
      for (let i = 0; i < n; i++) {
        let f;
        try { f = w.frames[i]; } catch (_) { continue; }
        if (isUsableHost(f)) {
          const area = (f.innerWidth || 0) * (f.innerHeight || 0);
          if (area > bestArea) { bestArea = area; best = f; }
        }
        walk(f);
      }
    })(topWin);
    return best;
  }

  function resolveHost() {
    let top = null;
    try { top = window.top; } catch (_) { top = null; }
    if (!top) return isUsableHost(window) ? window : null;
    let host = null;
    try { host = pickHost(top); } catch (_) { host = null; }
    if (!host && isUsableHost(window)) host = window;
    return host;
  }

  function bootstrap() {
    const CSS_BTN = 'position:fixed;right:20px;bottom:20px;z-index:2147483647;'
      + 'padding:10px 18px;border:none;border-radius:24px;background:#5C8DEF;color:#fff;'
      + 'font-size:14px;font-weight:600;cursor:pointer;font-family:system-ui,-apple-system,sans-serif;'
      + 'box-shadow:0 4px 14px rgba(0,0,0,.25);';
    const CSS_BOX = 'position:fixed;right:20px;bottom:76px;z-index:2147483647;width:320px;'
      + 'padding:12px 14px;border-radius:12px;background:#fff;color:#222;'
      + 'font-size:13px;line-height:1.6;font-family:system-ui,-apple-system,sans-serif;'
      + 'box-shadow:0 6px 24px rgba(0,0,0,.22);white-space:pre-wrap;word-break:break-all;';

    const host = resolveHost();
    if (!host) return;             // 整棵树里没有能放按钮的地方
    if (host !== window) return;   // 不是被选中的那一层：让选中的去注入

    try {
      if (host.__kbExportInjected) return;
      host.__kbExportInjected = true;
    } catch (_) { /* 设不上就算了，顶多多一个按钮 */ }

    const doc = host.document;

    const btn = doc.createElement('button');
    btn.textContent = '📤 导出课表';
    btn.style.cssText = CSS_BTN;

    const box = doc.createElement('div');
    box.style.cssText = CSS_BOX + 'display:none;';

    const show = (txt) => { box.style.display = 'block'; box.textContent = txt; };

    btn.addEventListener('click', async () => {
      btn.disabled = true;
      btn.style.opacity = '.6';
      show('正在读取课表…');
      try {
        const data = await buildSchedule((msg) => show(msg));
        const missingStart = !data.semester_start;
        if (missingStart) data.semester_start = mondayOf(new Date());

        const name = 'schedule.json';
        const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = doc.createElement('a');
        a.href = url;
        a.download = name;
        doc.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 5000);

        const slots = data.courses.reduce((s, c) => s + c.slots.length, 0);
        show('✅ 导出完成，已下载 ' + name
          + '\n学期 ' + data.semester
          + '\n课程 ' + data.courses.length + ' 门 / 时段 ' + slots + ' 个'
          + '\n开学第一周 ' + data.semester_start
          + (missingStart ? '\n\n⚠️ 这个日期自动读取失败，用「本周周一」暂代了。'
            + '请在 App 里核对开学日期，否则周次会整体错位。' : '')
          + '\n\n下一步：去 DDL Killer →「导入课表」→ 选择这个文件');
      } catch (e) {
        const msg = String((e && e.message) || e);
        if (msg === 'SESSION_EXPIRED') {
          show('❌ 没读到课表，教务系统把请求弹回了登录页。\n\n'
            + '请先登录教务系统、进到课表页面，再点一次「导出课表」。');
        } else {
          show('❌ 失败：' + msg + '\n\n可再点一次重试。');
        }
      } finally {
        btn.disabled = false;
        btn.style.opacity = '1';
      }
    });

    doc.body.appendChild(btn);
    doc.body.appendChild(box);
  }

  // ───────────── 导出（供离线单测使用） ─────────────
  const API = {
    splitLines, isBracketOnly, brackets, parseWeeks, parsePeriods, parseKey,
    canonicalName, extractGroup, parseSKSJ, parseItems, groupCourses, courseId,
    buildPeriodTables, normalizeDate, mondayOf, shiftDays, buildSchedule,
    FALLBACK_PERIOD_TIMES, ENDPOINTS,
  };

  if (typeof window !== 'undefined' && typeof document !== 'undefined') {
    window.__kbExport = API;
    // 自检日志：装好却没看到按钮时，按 F12 看这行就知道脚本有没有跑、跑在哪一层。
    try {
      const h = resolveHost();
      console.log('[课表导出] 已注入 v' + VERSION
        + ' | url=' + location.href
        + ' | 本层=' + window.innerWidth + 'x' + window.innerHeight
        + ' | 有body=' + !!document.body
        + ' | 子frame数=' + window.frames.length
        + ' | 选定宿主=' + (h ? h.location.href : '(无，本层不放按钮)'));
    } catch (_) { /* 日志失败无所谓 */ }
    try {
      bootstrap();
    } catch (e) {
      console.error('[课表导出] 注入失败：', e);
    }
  }
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = API;
  }
})();
