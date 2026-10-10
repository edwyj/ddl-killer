import {db} from './db.js';

export function isBeta() { return process.env.RELEASE_CHANNEL === 'beta'; }
export function betaAllowed(uid) {
  if (!isBeta()) return true;
  return (process.env.BETA_ALLOWED_USER_IDS || '').split(',').some(value => /^\d+$/.test(value) && Number(value) === uid);
}
export function betaGeneration() {
  if (!isBeta()) return null;
  return db.prepare("SELECT value FROM beta_meta WHERE key='generation'").get()?.value || null;
}
export function mountBetaBoundary(app) {
  if (!isBeta()) return;
  db.exec('CREATE TABLE IF NOT EXISTS beta_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  if (!betaGeneration() || !/^\d+(,\d+)*$/.test(process.env.BETA_ALLOWED_USER_IDS || '')) {
    throw new Error('Beta requires a refreshed snapshot and explicit allowed account IDs');
  }
  app.use((req, res, next) => {
    if (req.path.startsWith('/api/internal/') ||
        ['/api/auth/setup', '/api/auth/register'].includes(req.path)) {
      return res.status(403).json({error:'测试版仅供已获授权的账号使用'});
    }
    next();
  });
}
