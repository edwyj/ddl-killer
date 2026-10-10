import {readFileSync,statSync} from 'node:fs';
import {resolve} from 'node:path';
import {isBeta} from './beta.js';

export function mountBetaDownloads(app,auth,limit) {
  if(!isBeta())return;
  const root=resolve(process.env.BETA_RELEASE_DIR || '/app/beta-releases');
  function release() {
    const info=JSON.parse(readFileSync(resolve(root,'release.json'),'utf8'));
    const file=resolve(root,'app-beta-release.apk');
    if(!/^\d+\.\d+\.\d+-beta\.\d+$/.test(info.version) ||
      !Number.isSafeInteger(info.build_number) || info.build_number<1 ||
      !/^[a-f0-9]{64}$/.test(info.sha256) || info.bytes!==statSync(file).size)
      throw new Error('Beta release is not ready');
    return {info,file};
  }
  app.get('/api/beta/release',auth,(req,res)=>{
    try {
      const {info}=release();
      res.set('Cache-Control','private, no-store');
      res.json({...info,apk_url:'/api/beta/apk'});
    }catch{res.status(503).json({error:'测试安装包还在准备中，请稍后重试。'});}
  });
  app.get('/api/beta/apk',auth,limit('beta-apk',60,5*60000,req=>String(req.user.uid)),(req,res,next)=>{
    let current;
    try{current=release();}
    catch{return res.status(503).json({error:'测试安装包还在准备中，请稍后重试。'});}
    res.set({'Cache-Control':'private, no-store','X-Robots-Tag':'noindex, nofollow',
      'Content-Type':'application/vnd.android.package-archive'});
    res.download(current.file,`DDL_Killer_Beta_${current.info.version}.apk`,error=>{
      if(error && !res.headersSent)next(error);
    });
  });
}
