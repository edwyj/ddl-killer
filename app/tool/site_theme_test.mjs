import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const read = file => readFileSync(new URL('../'+file,import.meta.url),'utf8');
const source = read('web/site-theme.js');
function page({saved, legacy, cookie = '', dark = false, blocked = false} = {}) {
  const events = {}, mediaEvents = {}, store = new Map();
  if (saved) store.set('ddl_theme_mode', saved);
  if (legacy) store.set('flutter.theme_mode', JSON.stringify(legacy));
  const media = {matches:dark, addEventListener:(name, listener) => mediaEvents[name] = listener};
  const document = {cookie, hidden:false, documentElement:{dataset:{},style:{}},
    querySelectorAll:() => [], querySelector:() => null, addEventListener:(name, listener) => events[name] = listener};
  const context = {document, location:{hostname:'app.ddlkiller.com',protocol:'https:'},
    matchMedia:() => media, localStorage:{getItem:key => {if (blocked) throw Error('blocked');return store.get(key) || null;},
      setItem:(key, value) => {if (blocked) throw Error('blocked');store.set(key, value);}},
    addEventListener:(name, listener) => events[name] = listener};
  if (blocked) Object.defineProperty(document,'cookie',{get:() => {throw Error('blocked');},set:() => {throw Error('blocked');}});
  context.window = context;
  vm.runInNewContext(source, context);
  return {context, document, events, media, mediaEvents, store};
}
const fresh = page({dark:true});
assert.equal(fresh.document.documentElement.dataset.theme,'dark','first paint follows OS');
fresh.media.matches = false;fresh.mediaEvents.change();
assert.equal(fresh.document.documentElement.dataset.theme,'light');
fresh.context.DDLTheme.write('dark');
fresh.mediaEvents.change();
assert.equal(fresh.document.documentElement.dataset.theme,'dark','explicit choice overrides OS');
assert.equal(fresh.store.get('ddl_theme_mode'),'dark');
assert.match(fresh.document.cookie,/Domain=ddlkiller.com.*Secure/);
assert.equal(page({saved:'dark',dark:false}).document.documentElement.dataset.theme,'dark','refresh uses cached mode');
assert.equal(page({saved:'light',cookie:'ddl_theme=dark'}).document.documentElement.dataset.theme,'dark','shared subdomain preference wins');
assert.equal(page({legacy:'dark'}).document.documentElement.dataset.theme,'dark','existing Flutter users keep choice');
assert.equal(page({saved:'garbage',dark:true}).document.documentElement.dataset.theme,'dark');
const blocked = page({blocked:true,dark:true});
blocked.context.DDLTheme.write('light');
assert.equal(blocked.document.documentElement.dataset.theme,'light','restricted storage must not prevent switching');
const changes=[];
fresh.context.DDLTheme.watch(value=>changes.push(value));
fresh.document.cookie = 'ddl_theme=light';fresh.events.focus();
assert.deepEqual(changes,['light']);
assert.equal(fresh.document.documentElement.dataset.theme,'light','returning from another subdomain updates appearance');
fresh.context.DDLTheme.write('not-a-mode');
assert.equal(fresh.document.documentElement.dataset.theme,'light');
for (const file of ['../website/index.html','../website/help.html','../website/privacy.html','../download.html','web/kebiao-help.html','web/hitsz-kebiao-help.html','web/mcp-help.html']) {
  const html=read(file);
  assert.ok(html.includes('data-theme-control'),`${file} needs switch`);
  assert.ok(html.includes('/site-theme.css') && html.includes('/site-theme.js'),`${file} needs shared resources`);
  assert.ok(html.indexOf('/site-theme.js') < html.indexOf('</head>'),`${file} needs pre-paint appearance`);
}
assert.ok(!read('web/kebiao-help.html').includes('DDL Killer</b> v1.0.4'));
console.log('Site appearance passed: first paint, system changes, manual override, persistence, legacy migration, subdomain refresh and restricted storage.');
