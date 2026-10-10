import express from 'express';
import {createHash, randomBytes, randomUUID, timingSafeEqual} from 'node:crypto';
import {db} from './db.js';
import {auth, limit} from './security.js';
import {credentialDigest, normalizeScopes} from './mcp-credentials.js';

const issuer=(process.env.PUBLIC_ORIGIN || 'https://ddlkiller.com').replace(/\/$/,'');
const now=()=>new Date().toISOString();
const future=(ms)=>new Date(Date.now()+ms).toISOString();
const oauthError=(res,error='invalid_request',description='OAuth 请求无效')=>res.status(400).json({error,error_description:description});

function redirectAllowed(value) {
  if(typeof value!=='string' || value.length>2048 || value.includes('*')) return false;
  try {
    const uri=new URL(value);
    if(uri.username || uri.password || uri.hash) return false;
    const loopback=['127.0.0.1','localhost','[::1]'].includes(uri.hostname);
    return (uri.protocol==='https:' && !loopback) || (uri.protocol==='http:' && loopback);
  } catch { return false; }
}
function registered(id) {
  const row=db.prepare('SELECT * FROM mcp_registered_clients WHERE id=? AND disabled_at IS NULL').get(id);
  return row ? {...row,redirectUris:JSON.parse(row.redirect_uris_json)} : null;
}
function parseScopes(value) {
  if(typeof value!=='string' || !value.trim()) throw new Error('缺少 scope');
  return normalizeScopes(value.trim().split(/\s+/));
}
function safeEqual(a,b) {
  const x=Buffer.from(a),y=Buffer.from(b);
  return x.length===y.length && timingSafeEqual(x,y);
}
function recentLogin(req,res,next) {
  const session=typeof req.user?.sid==='string' && db.prepare('SELECT created_at FROM sessions WHERE id=? AND user_id=?').get(req.user.sid,req.user.uid);
  if(!session || session.created_at<Date.now()-15*60000) return res.status(401).json({error:'授权前请重新登录',code:'REAUTH_REQUIRED'});
  next();
}
function rawToken(prefix) { return `${prefix}${randomBytes(32).toString('base64url')}`; }
function insertCredential(clientId,kind,raw,familyId,expiresAt) {
  db.prepare(`INSERT INTO mcp_credentials(id,client_id,kind,token_prefix,secret_hash,family_id,expires_at,created_at)
    VALUES(?,?,?,?,?,?,?,?)`).run(randomUUID(),clientId,kind,raw.slice(0,20),credentialDigest(raw),familyId,expiresAt,now());
}
function issuePair(clientId,scopes,familyId=randomUUID()) {
  const access=rawToken('ddl_oauth_access_'),refresh=rawToken('ddl_oauth_refresh_');
  insertCredential(clientId,'oauth_access',access,familyId,future(3600000));
  insertCredential(clientId,'oauth_refresh',refresh,familyId,future(90*86400000));
  return {access_token:access,token_type:'Bearer',expires_in:3600,refresh_token:refresh,scope:scopes.join(' ')};
}

export function mountMcpOAuth(app) {
  app.get('/.well-known/oauth-authorization-server',(_req,res)=>res.json({
    issuer,authorization_endpoint:`${issuer}/api/mcp/oauth/authorize`,token_endpoint:`${issuer}/api/mcp/oauth/token`,
    registration_endpoint:`${issuer}/api/mcp/oauth/register`,response_types_supported:['code'],grant_types_supported:['authorization_code','refresh_token'],
    token_endpoint_auth_methods_supported:['none'],code_challenge_methods_supported:['S256'],scopes_supported:['mcp:read','mcp:tasks:write','mcp:schedule:draft','mcp:schedule:apply','mcp:delete','mcp:purge'],
  }));

  app.post('/api/mcp/oauth/register',limit('mcp-oauth-register',30), (req,res)=>{
    const body=req.body||{},uris=body.redirect_uris;
    if(typeof body.client_name!=='string' || !body.client_name.trim() || body.client_name.length>80 ||
      !Array.isArray(uris) || uris.length<1 || uris.length>5 || new Set(uris).size!==uris.length || !uris.every(redirectAllowed) ||
      (body.token_endpoint_auth_method && body.token_endpoint_auth_method!=='none') ||
      (body.response_types && JSON.stringify(body.response_types)!==JSON.stringify(['code'])) ||
      (body.grant_types && JSON.stringify(body.grant_types)!==JSON.stringify(['authorization_code','refresh_token']))) return oauthError(res,'invalid_client_metadata','客户端元数据不符合安全要求');
    const id=randomUUID(),created=now();
    db.prepare('INSERT INTO mcp_registered_clients(id,name,redirect_uris_json,created_at) VALUES(?,?,?,?)').run(id,body.client_name.trim(),JSON.stringify(uris),created);
    res.status(201).json({client_id:id,client_name:body.client_name.trim(),redirect_uris:uris,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code'],client_id_issued_at:Math.floor(Date.parse(created)/1000)});
  });

  app.get('/api/mcp/oauth/authorize',limit('mcp-oauth-authorize',60),(req,res,next)=>{
    if(typeof req.query.request_id==='string') return auth(req,res,()=>recentLogin(req,res,()=>{
      const row=db.prepare(`SELECT r.*,c.name client_name,c.disabled_at FROM mcp_oauth_requests r
        JOIN mcp_registered_clients c ON c.id=r.registered_client_id WHERE r.id=?`).get(req.query.request_id);
      if(!row || row.used_at || row.disabled_at || Date.parse(row.expires_at)<=Date.now() || (row.user_id!=null && row.user_id!==req.user.uid)) return oauthError(res,'invalid_request','授权请求已失效');
      db.prepare('UPDATE mcp_oauth_requests SET user_id=? WHERE id=? AND user_id IS NULL').run(req.user.uid,row.id);
      return res.json({requestId:row.id,clientName:row.client_name,scopes:JSON.parse(row.scopes_json),expiresAt:row.expires_at,state:row.state});
    }));
    try {
      const {response_type,client_id,redirect_uri,state,code_challenge,code_challenge_method}=req.query;
      if(response_type!=='code' || typeof state!=='string' || !state || typeof code_challenge!=='string' || code_challenge_method!=='S256') return oauthError(res);
      const client=registered(client_id);
      if(!client || !client.redirectUris.includes(redirect_uri)) return oauthError(res,'invalid_request','客户端或回调地址无效');
      const scopes=parseScopes(req.query.scope),id=randomUUID(),created=now(),expires=future(10*60000);
      db.prepare(`INSERT INTO mcp_oauth_requests(id,registered_client_id,user_id,redirect_uri,state,code_challenge,scopes_json,created_at,expires_at)
        VALUES(?,?,NULL,?,?,?,?,?,?)`).run(id,client.id,redirect_uri,state,code_challenge,JSON.stringify(scopes),created,expires);
      res.json({requestId:id,clientName:client.name,scopes,expiresAt:expires,state,loginRequired:true});
    } catch(error) { oauthError(res,'invalid_scope',error.message); }
  });

  app.post('/api/mcp/oauth/authorize',limit('mcp-oauth-authorize',60),auth,recentLogin,(req,res)=>{
    const row=db.prepare(`SELECT r.*,c.name client_name,c.disabled_at FROM mcp_oauth_requests r
      JOIN mcp_registered_clients c ON c.id=r.registered_client_id WHERE r.id=?`).get(req.body?.request_id);
    if(!row || row.used_at || row.disabled_at || Date.parse(row.expires_at)<=Date.now() || (row.user_id!=null && row.user_id!==req.user.uid)) return oauthError(res,'invalid_request','授权请求已失效');
    const redirect=new URL(row.redirect_uri); redirect.searchParams.set('state',row.state);
    if(req.body.approved!==true) {
      db.prepare('UPDATE mcp_oauth_requests SET used_at=? WHERE id=?').run(now(),row.id);
      redirect.searchParams.set('error','access_denied'); return res.json({redirect_uri:redirect.toString()});
    }
    try {
      const requested=JSON.parse(row.scopes_json),selected=normalizeScopes(req.body.scopes);
      if(selected.some((scope)=>!requested.includes(scope))) throw new Error('不能扩大原请求权限');
      const code=rawToken('ddl_oauth_code_'),stamp=now();
      db.exec('BEGIN IMMEDIATE');
      try {
        const changed=db.prepare('UPDATE mcp_oauth_requests SET used_at=?,user_id=COALESCE(user_id,?) WHERE id=? AND used_at IS NULL').run(stamp,req.user.uid,row.id);
        if(changed.changes!==1) throw new Error('授权请求已使用');
        db.prepare(`INSERT INTO mcp_oauth_codes(id,code_hash,registered_client_id,user_id,redirect_uri,code_challenge,scopes_json,expires_at,created_at)
          VALUES(?,?,?,?,?,?,?,?,?)`).run(randomUUID(),credentialDigest(code),row.registered_client_id,req.user.uid,row.redirect_uri,row.code_challenge,JSON.stringify(selected),future(5*60000),stamp);
        db.exec('COMMIT');
      } catch(error) { db.exec('ROLLBACK'); throw error; }
      redirect.searchParams.set('code',code); res.json({redirect_uri:redirect.toString()});
    } catch(error) { oauthError(res,'invalid_scope',error.message); }
  });

  app.post('/api/mcp/oauth/token',limit('mcp-oauth-token',120),express.urlencoded({extended:false,limit:'16kb'}),(req,res)=>{
    const body=req.body||{},client=registered(body.client_id);
    if(!client) return oauthError(res,'invalid_client','客户端无效');
    if(body.grant_type==='authorization_code') {
      const digest=credentialDigest(body.code),row=digest && db.prepare('SELECT * FROM mcp_oauth_codes WHERE code_hash=?').get(digest);
      if(!row || row.registered_client_id!==client.id || row.redirect_uri!==body.redirect_uri || row.used_at || Date.parse(row.expires_at)<=Date.now() || typeof body.code_verifier!=='string') return oauthError(res,'invalid_grant','授权码无效');
      const actual=createHash('sha256').update(body.code_verifier).digest('base64url');
      if(!safeEqual(actual,row.code_challenge)) return oauthError(res,'invalid_grant','PKCE 校验失败');
      const scopes=JSON.parse(row.scopes_json),clientId=randomUUID(),expires=future(90*86400000),stamp=now();
      db.exec('BEGIN IMMEDIATE');
      try {
        const changed=db.prepare('UPDATE mcp_oauth_codes SET used_at=? WHERE id=? AND used_at IS NULL').run(stamp,row.id);
        if(changed.changes!==1) throw new Error('used');
        if(db.prepare('SELECT count(*) n FROM mcp_clients WHERE user_id=? AND revoked_at IS NULL AND expires_at>?').get(row.user_id,stamp).n>=10) throw new Error('limit');
        db.prepare(`INSERT INTO mcp_clients(id,user_id,name,client_type,scopes_json,expires_at,created_at,oauth_registered_client_id)
          VALUES(?,?,?,'oauth',?,?,?,?)`).run(clientId,row.user_id,client.name,JSON.stringify(scopes),expires,stamp,client.id);
        const pair=issuePair(clientId,scopes); db.exec('COMMIT'); res.json(pair);
      } catch(error) { db.exec('ROLLBACK'); oauthError(res,'invalid_grant',error.message==='limit'?'有效连接已达上限':'授权码已使用'); }
      return;
    }
    if(body.grant_type==='refresh_token') {
      const digest=credentialDigest(body.refresh_token),row=digest && db.prepare(`SELECT k.*,c.scopes_json,c.oauth_registered_client_id,c.revoked_at client_revoked
        FROM mcp_credentials k JOIN mcp_clients c ON c.id=k.client_id WHERE k.secret_hash=? AND k.kind='oauth_refresh'`).get(digest);
      if(!row || row.oauth_registered_client_id!==client.id || row.client_revoked || Date.parse(row.expires_at)<=Date.now()) return oauthError(res,'invalid_grant','refresh token 无效');
      if(row.revoked_at) {
        const stamp=now();
        db.prepare('UPDATE mcp_credentials SET revoked_at=COALESCE(revoked_at,?) WHERE family_id=?').run(stamp,row.family_id);
        db.prepare('UPDATE mcp_clients SET revoked_at=COALESCE(revoked_at,?) WHERE id=?').run(stamp,row.client_id);
        return oauthError(res,'invalid_grant','refresh token 已重放，连接已撤销');
      }
      const original=JSON.parse(row.scopes_json); let scopes=original;
      try { if(body.scope) { scopes=parseScopes(body.scope); if(scopes.some((scope)=>!original.includes(scope))) throw new Error(); } }
      catch { return oauthError(res,'invalid_scope','刷新时只能缩小权限'); }
      db.exec('BEGIN IMMEDIATE');
      try {
        const stamp=now(),changed=db.prepare('UPDATE mcp_credentials SET revoked_at=? WHERE id=? AND revoked_at IS NULL').run(stamp,row.id);
        if(changed.changes!==1) throw new Error('replay');
        db.prepare("UPDATE mcp_credentials SET revoked_at=? WHERE family_id=? AND kind='oauth_access' AND revoked_at IS NULL").run(stamp,row.family_id);
        const pair=issuePair(row.client_id,scopes,row.family_id);
        db.prepare('UPDATE mcp_clients SET scopes_json=?,expires_at=? WHERE id=?').run(JSON.stringify(scopes),future(90*86400000),row.client_id);
        db.exec('COMMIT'); res.json(pair);
      } catch { db.exec('ROLLBACK'); oauthError(res,'invalid_grant','refresh token 无效'); }
      return;
    }
    oauthError(res,'unsupported_grant_type','不支持的 grant_type');
  });
}
