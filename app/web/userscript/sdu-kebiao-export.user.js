// ==UserScript==
// @name         山大 课表导出 → DDL Killer
// @namespace    https://ddlkiller.com/
// @version      1.0.5
// @description  在教务系统任意已登录页面，一键导出整学期课表为 schedule.json，供 DDL Killer「导入课表」使用。
// @author       Andy
// 覆盖整个教务域名：选课期间登录会先落在选课系统入口页（需点「进入首页」才到智慧教学平台），
// 非选课期则直接进。两条路径都要能出现导出按钮。
// @match        https://bkzhjx.wh.sdu.edu.cn/*
// @grant        none
// @downloadURL  https://ddlkiller.com/userscript/sdu-kebiao-export.user.js
// @updateURL    https://ddlkiller.com/userscript/sdu-kebiao-export.user.js
// @run-at       document-idle
// ==/UserScript==
//
// ─────────────────────────────────────────────────────────────────────────
// 安全说明（重要）
//   本脚本全程【只读】，且完全在你的浏览器里运行：
//     · 不索取、不读取、不外传你的账号和密码
//     · 不保存 cookie / token，不使用任何外部服务器
//     · 只向教务系统自己的课表查询接口发 POST，等价于你在页面上翻看每周课表
//   它产出的是一个 schedule.json 文件，下载到你自己电脑上，由你自行决定是否导入。
// ─────────────────────────────────────────────────────────────────────────

(function () {
  'use strict';

  // ───────────── 配置 ─────────────
  const VERSION = '1.0.5';   // 与文件头的 @version 保持一致
  const BASE = 'https://bkzhjx.wh.sdu.edu.cn';
  const XSKB_URL = BASE + '/jsxsd/xskb/xskb_list.do';
  const SEMESTER = '2026-2027-1';
  const KBJCMSID = '3EDEF7861CC54AEFBB29BF71DA72C601';

  // 学期第一周的周一。DDL Killer 用它把「第N周」换算成具体日期。
  // ⚠️ 换学期时改这里（和后端 SEMESTER_START 保持一致），否则课程会整体错位。
  const SEMESTER_START = '2026-08-31';

  // 实际抓取的周数。山大一个学期约 18-20 周，抓 20 周足够覆盖到期末。
  // 教务的周次下拉框是固定的 1-30，读它问不出"本学期共几周"，所以直接定一个够用的数。
  // ⚠️ 万一某个学期超过 20 周，把这里调大即可（别超过 WEEK_CAP）。
  const WEEKS_TO_FETCH = 20;
  const WEEK_CAP = 30;       // 硬上限：防止解析异常时打爆教务
  const WEEK_FALLBACK = 20;  // 周次发现失败时的兜底
  const FETCH_GAP_MS = 200;  // 每周之间停顿，别给教务压力

  const TIME_NOTE = '历史简化作息示例：大节开始时间正确；'
    + '实际一小节 50 分钟+10 分钟课间；展示按每大节 2 小时简化。';

  // ───────────── 文本提取 ─────────────
  // 近似 BeautifulSoup 的 get_text(sep, strip=True)：各后代文本节点去空白后按 sep 拼接。
  function getText(el, sep) {
    if (sep === undefined) sep = '';
    const parts = [];
    (function walk(n) {
      for (const c of n.childNodes) {
        if (c.nodeType === 3) {                       // 文本节点
          const t = c.nodeValue.trim();
          if (t) parts.push(t);
        } else if (c.nodeType === 1) {                // 元素节点
          walk(c);
        }
      }
    })(el);
    return parts.join(sep);
  }

  // ───────────── 纯解析函数（可离线单测） ─────────────

  /** '第1-16周' → [1..16]；'第5周,第7周,第9周,第11周' → [5,7,9,11] */
  function parseWeeks(text) {
    const out = [];
    const parts = String(text == null ? '' : text).replace(/第/g, '').split(/[,，]/);
    for (const raw of parts) {
      const part = raw.trim();
      if (!part) continue;
      let m = part.match(/^(\d+)\s*[-－~～]\s*(\d+)/);
      if (m) {
        for (let i = Number(m[1]); i <= Number(m[2]); i++) out.push(i);
        continue;
      }
      m = part.match(/^(\d+)/);
      if (m) out.push(Number(m[1]));
    }
    return [...new Set(out)].sort((a, b) => a - b);
  }

  /** '[03-04节]' → [3,4]；'[09-10,11节]' → [9,10,11] */
  function parsePeriods(text) {
    const m = String(text == null ? '' : text).match(/\[([^\]]+)\]/);
    if (!m) return [];
    const nums = (m[1].match(/\d+/g) || []).map(Number);
    return [...new Set(nums)].sort((a, b) => a - b);
  }

  /** 解析一个 kbcontent1 课程块 → {name,id,section,weeks,periods,room,group?}；无课程则 null */
  function parseBlock(block) {
    const fonts = block.querySelectorAll('font');
    let course = null;
    let weekTxt = '';
    let room = '';
    for (const f of fonts) {
      const title = f.getAttribute('title') || '';
      if (title === '周次(节次)') {
        weekTxt = getText(f);
      } else if (title === '教室') {
        room = getText(f);
      } else {
        const t = getText(f);
        // 课程号必须容许字母数字混排（如 sd03020250），只写 \d 会漏掉两字母开头的课
        const m = t.match(/\(([A-Za-z0-9]+)\s*-\s*(\d+)\s*\)/);
        if (m) {
          course = { name: t.slice(0, m.index).trim(), id: m[1], section: Number(m[2]) };
          const g = t.slice(m.index + m[0].length).match(/\(([^)]+)\)/);
          if (g) course.group = g[1];
        }
      }
    }
    if (!course) return null;
    course.weeks = parseWeeks(weekTxt);
    course.periods = parsePeriods(weekTxt);
    course.room = room;
    return course;
  }

  /** 解析一页课表网格 → [{name,id,section,weeks,periods,room,weekday,group?}] */
  function parsePage(doc, fallbackPeriods) {
    const ths = doc.querySelectorAll('th');
    let th = null;
    for (const t of ths) if (getText(t) === '星期一') { th = t; break; }
    if (!th) for (const t of ths) if (getText(t).indexOf('星期一') !== -1) { th = t; break; }
    if (!th) return [];
    const table = th.closest('table');
    if (!table) return [];

    const out = [];
    for (const tr of table.querySelectorAll('tr')) {
      // 序号列是 <th> 不是 <td>，两种都要收
      const cells = tr.querySelectorAll('td,th');
      if (!cells.length) continue;
      const label = getText(cells[0], ' ');
      let rowPeriods = fallbackPeriods;
      if (/第[一二三四五]?.*?\(?(\d[\d,，]*小节?)\)?/.test(label)) {
        rowPeriods = (label.match(/\d+/g) || []).map(Number);
      }
      // cells[1..7] 依次是 星期一..星期日
      for (let ci = 1; ci <= 7; ci++) {
        const cell = cells[ci];
        if (!cell) continue;
        for (const block of cell.querySelectorAll('.kbcontent1')) {
          const b = parseBlock(block);
          if (b) {
            b.weekday = ci;
            if (!b.periods.length) b.periods = rowPeriods.slice();
            out.push(b);
          }
        }
      }
    }
    return out;
  }

  /** 课表下方的课程列表 → {course_id: {teacher,type,attr,name}} */
  function loadCourseList(doc) {
    const meta = {};
    for (const tr of doc.querySelectorAll('tr')) {
      const tds = [...tr.querySelectorAll('td,th')].map((td) => getText(td, ' '));
      if (tds.length >= 9 && /^\d+$/.test(tds[0])) {
        meta[tds[2]] = { teacher: tds[4], type: tds[7], attr: tds[8], name: tds[3] };
      }
    }
    return meta;
  }

  /**
   * 从课表页推断本学期总周数。
   * 原则：宁可多抓，不能少抓 —— 多抓只是多几个请求+空网格；少抓会让只在后段开课的整门课消失。
   */
  function discoverWeeksTotal(html) {
    const valid = (n) => Number.isFinite(n) && n >= 8 && n <= WEEK_CAP;

    // ① 首选：周次下拉框（option 文本形如「第N周」）——这是权威值
    try {
      const doc = new DOMParser().parseFromString(html, 'text/html');
      const fromOptions = [];
      for (const o of doc.querySelectorAll('option')) {
        const m = (o.textContent || '').trim().match(/第\s*(\d{1,2})\s*周/);
        if (m) fromOptions.push(Number(m[1]));
      }
      const ok = fromOptions.filter(valid);
      if (ok.length) return { total: Math.max.apply(null, ok), source: 'select' };
    } catch (_) { /* 落到下一级 */ }

    // ② 次选：整页文本里出现的「第N周」
    const all = [];
    const re = /第\s*(\d{1,2})\s*周/g;
    let m;
    while ((m = re.exec(html)) !== null) all.push(Number(m[1]));
    const ok2 = all.filter(valid);
    if (ok2.length) return { total: Math.max.apply(null, ok2), source: 'text' };

    // ③ 兜底
    return { total: WEEK_FALLBACK, source: 'fallback' };
  }

  // ───────────── 抓取 ─────────────
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  async function fetchWeek(zc) {
    const body = new URLSearchParams({
      cj0701id: '', zc: String(zc), demo: '',
      xnxq01id: SEMESTER, sfFD: '1', wkbkc: '1', kbjcmsid: KBJCMSID,
    });
    const r = await fetch(XSKB_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
      credentials: 'same-origin',   // 同源请求，自动带上你当前的登录态
    });
    if (!r.ok) throw new Error('第' + zc + '周请求失败：HTTP ' + r.status);
    const html = await r.text();
    if (html.indexOf('userAccount') !== -1 || html.indexOf('用户登录') !== -1) {
      throw new Error('SESSION_EXPIRED');
    }
    return html;
  }

  /** 抓完整学期 → 组装成 DDL Killer 的 schedule.json 结构 */
  async function buildSchedule(onProgress) {
    const firstHtml = await fetchWeek(1);
    const doc1 = new DOMParser().parseFromString(firstHtml, 'text/html');
    // 周次发现的结果再夹一道：下拉框永远写 1-30，问不出真正的学期长度，
    // 照单全收会白抓 10 周。抓 20 周足够，多抓只是让同学多等一会儿。
    const found = discoverWeeksTotal(firstHtml);
    const total = Math.min(found.total, WEEKS_TO_FETCH);
    const source = found.source;

    const all = [];
    const seen = new Set();
    for (let zc = 1; zc <= total; zc++) {
      const html = zc === 1 ? firstHtml : await fetchWeek(zc);
      const doc = zc === 1 ? doc1 : new DOMParser().parseFromString(html, 'text/html');
      const blocks = parsePage(doc, [1, 2]);
      let added = 0;
      for (const b of blocks) {
        const key = b.id + '|' + b.section + '|' + b.weekday + '|' + b.periods.join(',');
        if (!seen.has(key)) { seen.add(key); all.push(b); added++; }
      }
      if (onProgress) onProgress(zc, total, blocks.length, added);
      if (zc < total) await sleep(FETCH_GAP_MS);
    }

    const meta = loadCourseList(doc1);

    // 组装课程结构
    const courses = {};
    for (const b of all) {
      if (!courses[b.id]) {
        const mi = meta[b.id] || {};
        courses[b.id] = {
          course_id: b.id,
          name: b.name,
          teacher: mi.teacher || '',
          type: mi.type || '',
          attr: mi.attr || '',
          slots: [],
        };
      }
      courses[b.id].slots.push({
        section: b.section,
        group: b.group || '',
        weekday: b.weekday,
        periods: b.periods,
        weeks: b.weeks,
        room: b.room,
      });
    }

    // 在课程列表里但没出现在网格中的课（无固定上课时间）
    // 按 name 排序，且用码元比较而非 localeCompare —— 与参考实现的字符串排序逐字对齐
    const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
    const noFixed = Object.keys(meta)
      .filter((k) => !courses[k])
      .map((k) => meta[k])
      .sort((a, b) => cmpStr(a.name, b.name));

    return {
      semester: SEMESTER,
      semester_start: SEMESTER_START,   // App 靠这个算「第几周」，缺了会整体错位
      updated_at: nowStr(),
      period_times: {
        '1': ['08:00', '10:00'], '2': ['10:00', '12:00'],
        '3': ['14:00', '16:00'], '4': ['16:00', '18:00'],
        '5': ['19:00', '21:00'],
      },
      period_to_block: {
        '1': 1, '2': 1, '3': 2, '4': 2, '5': 3, '6': 3,
        '7': 4, '8': 4, '9': 5, '10': 5, '11': 5,
      },
      time_note: TIME_NOTE,
      week_source: source,
      courses: Object.keys(courses)
        .sort()
        .map((k) => courses[k]),
      no_fixed_time: noFixed,
    };
  }

  function nowStr() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  // ───────────── 浏览器 UI ─────────────
  //
  // 页面结构（2026-09-11 用真实登录态实测过）：
  //   顶层 xsMainV.jsp 是**普通 body 文档**，内容区是它动态插进去的 <iframe>，并不是 frameset。
  //   真正会咬人的是这个：教务首页里存在【0×0 的 about:blank iframe】。
  //   Tampermonkey 默认往每个 frame 各注一份，如果那个 0×0 的 frame 先跑，
  //   它就会把守卫抢走、把按钮建在自己零尺寸的文档里 —— 症状正是"脚本装好了却看不到按钮"，
  //   而且不报任何错。所以宿主必须【确定性地】选，不能谁先跑谁赢：
  //   每一层都用同一套规则算出同一个宿主，只有被选中的那一层真正注入。
  //
  //   另外保留 frameset 分支：强智的其他部署确实是 frameset 架构，那种文档
  //   document.body 返回的是 <frameset> 元素本身（不是 null），往里面 appendChild
  //   同样不报错也不渲染。两条路都得能走。
  function hasRealBody(doc) {
    const b = doc && doc.body;
    return !!b && b.tagName !== 'FRAMESET';
  }

  /** 这个窗口够不够格当宿主：要有真 body，而且真有可见尺寸（挡掉 0×0 / display:none 的 iframe） */
  function isUsableHost(win) {
    try {
      if (!hasRealBody(win.document)) return false;
      if ((win.innerWidth || 0) < 320 || (win.innerHeight || 0) < 240) return false;
      return true;
    } catch (_) { return false; }   // 跨域，摸不得
  }

  /** 从顶层往下挑唯一宿主：顶层可用就用顶层，否则取面积最大的可用 frame。 */
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

  /** 本页唯一的注入宿主；也算不出来就返回 null（那就别乱放按钮）。 */
  function resolveHost() {
    let top = null;
    try { top = window.top; } catch (_) { top = null; }
    if (!top) return isUsableHost(window) ? window : null;
    let host = null;
    try { host = pickHost(top); } catch (_) { host = null; }  // 遍历途中撞上跨域
    if (!host && isUsableHost(window)) host = window;         // 退而求其次：就地
    return host;
  }

  function bootstrap() {
    const CSS_BTN = 'position:fixed;right:20px;bottom:20px;z-index:2147483647;'
      + 'padding:10px 18px;border:none;border-radius:24px;background:#5C8DEF;color:#fff;'
      + 'font-size:14px;font-weight:600;cursor:pointer;font-family:system-ui,-apple-system,sans-serif;'
      + 'box-shadow:0 4px 14px rgba(0,0,0,.25);';
    const CSS_BOX = 'position:fixed;right:20px;bottom:76px;z-index:2147483647;width:300px;'
      + 'padding:12px 14px;border-radius:12px;background:#fff;color:#222;'
      + 'font-size:13px;line-height:1.6;font-family:system-ui,-apple-system,sans-serif;'
      + 'box-shadow:0 6px 24px rgba(0,0,0,.22);white-space:pre-wrap;word-break:break-all;';

    const host = resolveHost();
    if (!host) return;             // 整棵树里没有能放按钮的地方
    if (host !== window) return;   // 不是被选中的那一层：让选中的去注入，否则会出现好几个按钮

    // 兜底守卫：正常情况下每一层算出的宿主都一样、只有一层会走到这里，
    // 但万一窗口尺寸还没定下来（比如 frame 刚创建），两层可能都认为自己是宿主。
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
        const data = await buildSchedule((zc, total, n, added) => {
          show('抓取第 ' + zc + '/' + total + ' 周…\n本页 ' + n + ' 块，新增 ' + added);
        });
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
          + '\n课程 ' + data.courses.length + ' 门 / 时段 ' + slots + ' 个'
          + '\n周次来源：' + data.week_source
          + (data.no_fixed_time.length ? '\n（另有 ' + data.no_fixed_time.length + ' 门无固定时间课程，已记在文件里）' : '')
          + '\n\n下一步：去 DDL Killer →「导入课表」→ 把文件内容粘进去');
      } catch (e) {
        const msg = String(e && e.message || e);
        if (msg === 'SESSION_EXPIRED') {
          show('❌ 没读到课表，教务系统把请求弹回了登录页。\n\n'
            + '最常见的原因：选课期间登录会先停在【选课系统】的入口页，\n'
            + '那里还读不到课表 —— 请先点「进入首页」进入智慧教学平台，\n'
            + '再点一次「导出课表」。\n\n'
            + '若已经在智慧教学平台里，说明登录过期了，重新登录即可。');
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

  // ───────────── 导出（供离线单测 / 差分测试使用） ─────────────
  const API = {
    getText, parseWeeks, parsePeriods, parseBlock, parsePage,
    loadCourseList, discoverWeeksTotal, buildSchedule,
    SEMESTER, SEMESTER_START, WEEKS_TO_FETCH, WEEK_CAP, WEEK_FALLBACK,
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
