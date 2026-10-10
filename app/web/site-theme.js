/* Shared appearance only. No account data or credentials are stored here. */
(() => {
  const key = 'ddl_theme_mode', cookie = 'ddl_theme';
  const valid = value => ['system', 'light', 'dark'].includes(value);
  const media = matchMedia('(prefers-color-scheme: dark)');
  function read() {
    try {
      const value = document.cookie.split(';').map(s => s.trim())
        .find(s => s.startsWith(cookie + '='))?.slice(cookie.length + 1);
      if (valid(value)) return value;
    } catch (_) { /* Storage can be unavailable in private/restricted contexts. */ }
    try {
      const value = localStorage.getItem(key);
      if (valid(value)) return value;
      const legacy = JSON.parse(localStorage.getItem('flutter.theme_mode') || 'null');
      if (valid(legacy)) return legacy;
    } catch (_) {}
    return null;
  }
  let mode = read() || 'system';
  const listeners = new Set();
  const controls = [];
  function apply() {
    const theme = mode === 'system' ? (media.matches ? 'dark' : 'light') : mode;
    document.documentElement.dataset.theme = theme;
    document.documentElement.dataset.themeMode = mode;
    document.documentElement.style.colorScheme = theme;
    controls.forEach(control => control.update());
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'dark' ? '#201c24' : '#fffdfd');
  }
  function write(value) {
    if (!valid(value)) return;
    mode = value;
    try { localStorage.setItem(key, value); } catch (_) {}
    try {
      const domain = location.hostname === 'ddlkiller.com' || location.hostname.endsWith('.ddlkiller.com')
        ? '; Domain=ddlkiller.com' : '';
      document.cookie = `${cookie}=${value}; Path=/; Max-Age=31536000; SameSite=Lax${domain}${location.protocol === 'https:' ? '; Secure' : ''}`;
    } catch (_) {}
    apply();
  }
  function refresh() {
    const next = read() || 'system';
    if (next !== mode) {
      mode = next;
      apply();
      listeners.forEach(listener => listener(mode));
    }
  }
  window.DDLTheme = { read, write, watch: listener => listeners.add(listener) };
  apply(); // Synchronous head script: resolve appearance before first paint.
  media.addEventListener('change', apply);
  window.addEventListener('storage', refresh);
  window.addEventListener('focus', refresh);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  document.addEventListener('DOMContentLoaded', () => {
    const choices = [['system', '跟随系统', '◐'], ['light', '浅色', '☀'], ['dark', '深色', '☾']];
    document.querySelectorAll('[data-theme-control]').forEach((host, index) => {
      const wrapper = document.createElement('div');
      wrapper.className = 'site-theme-switch';
      const trigger = document.createElement('button');
      trigger.type = 'button'; trigger.className = 'site-theme-trigger';
      trigger.setAttribute('aria-label', '外观模式');
      trigger.setAttribute('aria-haspopup', 'menu');
      trigger.setAttribute('aria-expanded', 'false');
      const icon = document.createElement('span');
      icon.className = 'site-theme-icon'; icon.setAttribute('aria-hidden', 'true');
      const label = document.createElement('span');
      const chevron = document.createElement('span');
      chevron.className = 'site-theme-chevron'; chevron.setAttribute('aria-hidden', 'true');
      trigger.append(icon, label, chevron);
      const menu = document.createElement('div');
      menu.className = 'site-theme-menu'; menu.hidden = true;
      menu.id = `site-theme-menu-${index}`;
      menu.setAttribute('role', 'menu'); menu.setAttribute('aria-label', '外观模式');
      trigger.setAttribute('aria-controls', menu.id);
      const items = choices.map(([value, text, glyph]) => {
        const item = document.createElement('button');
        item.type = 'button'; item.className = 'site-theme-option'; item.tabIndex = -1;
        item.setAttribute('role', 'menuitemradio');
        const symbol = document.createElement('span');
        symbol.className = 'site-theme-icon'; symbol.textContent = glyph;
        symbol.setAttribute('aria-hidden', 'true');
        const name = document.createElement('span'); name.textContent = text;
        const check = document.createElement('span');
        check.className = 'site-theme-check'; check.textContent = '✓'; check.setAttribute('aria-hidden', 'true');
        item.append(symbol, name, check);
        item.addEventListener('click', () => { write(value); close(true); });
        menu.append(item);
        return item;
      });
      function close(restoreFocus = false) {
        menu.hidden = true; trigger.setAttribute('aria-expanded', 'false');
        if (restoreFocus) trigger.focus();
      }
      function open(last = false) {
        controls.forEach(control => control.close());
        menu.hidden = false; trigger.setAttribute('aria-expanded', 'true');
        items[last ? items.length - 1 : choices.findIndex(choice => choice[0] === mode)].focus();
      }
      trigger.addEventListener('click', () => { if (menu.hidden) open(); else close(); });
      trigger.addEventListener('keydown', event => {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault(); event.stopPropagation(); open(event.key === 'ArrowUp');
        }
      });
      wrapper.addEventListener('keydown', event => {
        if (menu.hidden) return;
        const current = items.indexOf(document.activeElement);
        if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) && current >= 0) {
          event.preventDefault();
          const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1
            : (current + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
          items[next].focus();
        } else if (event.key === 'Escape') {
          event.preventDefault(); event.stopPropagation(); close(true);
        } else if (event.key === 'Tab') close(true);
      });
      wrapper.addEventListener('focusout', event => {
        if (!wrapper.contains(event.relatedTarget)) close();
      });
      controls.push({ close, update() {
        const choice = choices.find(choice => choice[0] === mode);
        icon.textContent = choice[2]; label.textContent = choice[1];
        items.forEach((item, i) => item.setAttribute('aria-checked', String(choices[i][0] === mode)));
      }});
      wrapper.append(trigger, menu); host.append(wrapper);
    });
    apply();
    document.addEventListener('pointerdown', event => {
      if (!event.target.closest('.site-theme-switch')) controls.forEach(control => control.close());
    });
  });
})();
