import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

process.env.DB_PATH=':memory:';
process.env.JWT_SECRET='oauth-test-jwt-secret-at-least-32-characters';
process.env.MCP_TOKEN_PEPPER='oauth-test-pepper-at-least-32-characters';
process.env.PUBLIC_ORIGIN='https://ddlkiller.com';

const {db}=await import('../src/db.js');
const {createApp}=await import('../src/app.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const bcrypt=(await import('bcryptjs')).default;
createUserWithDefaultLists('oauth_owner',bcrypt.hashSync('Oauth-owner-password-123',4));
const server=createApp().listen(0,'127.0.0.1');
await new Promise((resolve)=>server.once('listening',resolve));
test.after(()=>{server.close();db.close();});
const base=`http://127.0.0.1:${server.address().port}`;
const verifier='oauth-verifier-that-is-long-enough-0123456789';
const challenge=createHash('sha256').update(verifier).digest('base64url');

async function json(path,method='GET',body,token) {
  const response=await fetch(base+path,{method,headers:{'content-type':'application/json',...(token?{authorization:`Bearer ${token}`}:{})},...(body?{body:JSON.stringify(body)}:{})});
  return {status:response.status,headers:response.headers,data:await response.json()};
}
async function form(path,body) {
  const response=await fetch(base+path,{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams(body)});
  return {status:response.status,data:await response.json()};
}
const register=(redirect_uris=['https://client.example/callback'])=>json('/api/mcp/oauth/register','POST',{client_name:'Test Agent',redirect_uris,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']});
const login=async()=> (await json('/api/auth/login','POST',{username:'oauth_owner',password:'Oauth-owner-password-123'})).data.token;

async function authorize(client,token,{redirect_uri=client.redirect_uris[0],scope='mcp:read mcp:schedule:draft',state='state-123'}={}) {
  const query=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri,scope,state,code_challenge:challenge,code_challenge_method:'S256'});
  const consent=await json(`/api/mcp/oauth/authorize?${query}`, 'GET', null, token);
  assert.equal(consent.status,200);
  return json('/api/mcp/oauth/authorize','POST',{request_id:consent.data.requestId,approved:true,scopes:consent.data.scopes},token);
}

test('metadata, DCR and redirect policy are strict',async()=>{
  const metadata=await json('/.well-known/oauth-authorization-server');
  assert.equal(metadata.status,200);
  assert.equal(metadata.data.issuer,'https://ddlkiller.com');
  assert.ok(metadata.data.code_challenge_methods_supported.includes('S256'));
  assert.equal((await register(['http://127.0.0.1:43123/callback'])).status,201);
  assert.equal((await register(['http://localhost:43123/callback'])).status,201);
  for(const uri of ['http://client.example/callback','https://*.example/callback','https://user@example.com/callback','https://client.example/callback#frag']) {
    assert.equal((await register([uri])).status,400,uri);
  }
});

test('authorization code requires exact redirect, state and PKCE, expires and works once',async()=>{
  const client=(await register()).data;
  const token=await login();
  const missingState=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:client.redirect_uris[0],scope:'mcp:read',code_challenge:challenge,code_challenge_method:'S256'});
  assert.equal((await json(`/api/mcp/oauth/authorize?${missingState}`,'GET',null,token)).status,400);
  const wrongRedirect=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:'https://client.example/other',scope:'mcp:read',state:'wrong',code_challenge:challenge,code_challenge_method:'S256'});
  assert.equal((await json(`/api/mcp/oauth/authorize?${wrongRedirect}`,'GET',null,token)).status,400);
  const approved=await authorize(client,token);
  assert.equal(approved.status,200);
  const redirect=new URL(approved.data.redirect_uri);
  assert.equal(redirect.searchParams.get('state'),'state-123');
  const code=redirect.searchParams.get('code');
  const wrong=await form('/api/mcp/oauth/token',{grant_type:'authorization_code',client_id:client.client_id,code,redirect_uri:client.redirect_uris[0],code_verifier:'wrong-verifier-that-is-long-enough-012345'});
  assert.equal(wrong.status,400);
  const good=await form('/api/mcp/oauth/token',{grant_type:'authorization_code',client_id:client.client_id,code,redirect_uri:client.redirect_uris[0],code_verifier:verifier});
  assert.equal(good.status,200);
  assert.match(good.data.access_token,/^ddl_oauth_access_/);
  assert.match(good.data.refresh_token,/^ddl_oauth_refresh_/);
  assert.equal((await json('/api/internal/mcp/exchange','POST',null,good.data.refresh_token)).status,401);
  assert.equal((await form('/api/mcp/oauth/token',{grant_type:'authorization_code',client_id:client.client_id,code,redirect_uri:client.redirect_uris[0],code_verifier:verifier})).status,400);
  assert.equal((await json('/api/internal/mcp/exchange','POST',null,good.data.access_token)).status,200);

  const expiring=await authorize(client,token,{state:'expires'});
  const expiredCode=new URL(expiring.data.redirect_uri).searchParams.get('code');
  db.prepare("UPDATE mcp_oauth_codes SET expires_at='2000-01-01T00:00:00.000Z' WHERE used_at IS NULL").run();
  assert.equal((await form('/api/mcp/oauth/token',{grant_type:'authorization_code',client_id:client.client_id,code:expiredCode,redirect_uri:client.redirect_uris[0],code_verifier:verifier})).status,400);
  db.prepare('UPDATE sessions SET created_at=?').run(Date.now()-16*60000);
  const staleSessionQuery=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:client.redirect_uris[0],scope:'mcp:read',state:'stale',code_challenge:challenge,code_challenge_method:'S256'});
  const staleRequest=await json(`/api/mcp/oauth/authorize?${staleSessionQuery}`,'GET');
  assert.equal((await json(`/api/mcp/oauth/authorize?request_id=${staleRequest.data.requestId}`,'GET',null,token)).status,401);
});

test('scope narrowing, disabled clients and refresh replay revocation',async()=>{
  const client=(await register()).data;
  const token=await login();
  const query=new URLSearchParams({response_type:'code',client_id:client.client_id,redirect_uri:client.redirect_uris[0],scope:'mcp:read mcp:tasks:write mcp:schedule:draft',state:'narrow',code_challenge:challenge,code_challenge_method:'S256'});
  const consent=await json(`/api/mcp/oauth/authorize?${query}`,'GET',null,token);
  const approved=await json('/api/mcp/oauth/authorize','POST',{request_id:consent.data.requestId,approved:true,scopes:['mcp:read']},token);
  const code=new URL(approved.data.redirect_uri).searchParams.get('code');
  const issued=await form('/api/mcp/oauth/token',{grant_type:'authorization_code',client_id:client.client_id,code,redirect_uri:client.redirect_uris[0],code_verifier:verifier});
  assert.equal(issued.data.scope,'mcp:read');
  const rotated=await form('/api/mcp/oauth/token',{grant_type:'refresh_token',client_id:client.client_id,refresh_token:issued.data.refresh_token,scope:'mcp:read'});
  assert.equal(rotated.status,200);
  assert.notEqual(rotated.data.refresh_token,issued.data.refresh_token);
  assert.equal((await form('/api/mcp/oauth/token',{grant_type:'refresh_token',client_id:client.client_id,refresh_token:issued.data.refresh_token})).status,400);
  assert.equal((await json('/api/internal/mcp/exchange','POST',null,rotated.data.access_token)).status,401);

  db.prepare('UPDATE mcp_registered_clients SET disabled_at=? WHERE id=?').run(new Date().toISOString(),client.client_id);
  assert.equal((await json(`/api/mcp/oauth/authorize?${query}`,'GET',null,token)).status,400);
});
