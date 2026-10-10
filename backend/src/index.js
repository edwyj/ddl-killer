import { createApp } from './app.js';
import { startReminderWorker } from './reminders.js';
import { startRetentionWorker } from './retention.js';
import { ensureSystemListsForAllUsers } from './default-lists.js';
import { seedScheduleFromFile } from './schedule.js';

const PORT = Number(process.env.PORT || 3000);
seedScheduleFromFile(1);        // 启动时:把旧全局课表迁移给首个账号(uid=1)——幂等
const backfilled = ensureSystemListsForAllUsers();  // 老账号补系统清单——幂等
if (backfilled) console.log(`[lists] 补齐系统清单 ${backfilled} 条`);
const app = createApp();
const mailTimer=setInterval(()=>app.locals.email.flush().catch(()=>console.warn('[mail] worker failed')),1000);
mailTimer.unref();
app.locals.email.flush().catch(()=>{});
startReminderWorker();
startRetentionWorker();         // 回收站 7 天 / 已完成 3 天到期清理
app.listen(PORT, () => console.log(`plan-api listening on :${PORT}`));
