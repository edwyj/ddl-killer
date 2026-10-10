import {randomUUID} from 'node:crypto';
export const mails=[];
export const emailOptions={send:async mail=>{mails.push(mail);return 'fixture-mail';}};
export async function registerVerified(app,base,body){
 const email='fixture-'+randomUUID()+'@example.com';
 const sent=await fetch(base+'/api/auth/email/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,captcha_id:body.captcha_id,captcha_code:body.captcha_code})});
 if(!sent.ok)return sent;const request=await sent.json();await app.locals.email.flush();
 const code=mails.findLast(m=>m.to===email)?.code;
 return fetch(base+'/api/auth/register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({username:body.username,password:body.password,email,request_id:request.request_id,code})});
}
