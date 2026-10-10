// A disposable real API for Flutter offline integration tests. Never opens production data.
process.env.DB_PATH=':memory:';process.env.JWT_SECRET='offline-integration-only';process.env.NODE_ENV='test';
const {createApp}=await import('../src/app.js');
const {createUserWithDefaultLists}=await import('../src/default-lists.js');
const {issueSession}=await import('../src/security.js');
const {default:bcrypt}=await import('bcryptjs');
const uid=createUserWithDefaultLists('offline_fixture',bcrypt.hashSync('fixture-password-only',4));
const app=createApp().listen(0,'127.0.0.1',()=>process.stdout.write(JSON.stringify({port:app.address().port,token:issueSession({id:uid,username:'offline_fixture'}),uid})+'\n'));
