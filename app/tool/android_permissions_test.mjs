import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync,readdirSync} from 'node:fs';
import path from 'node:path';

// Inspect the packaged APK, including permissions introduced by dependencies.
const sdk=process.env.ANDROID_HOME??process.env.ANDROID_SDK_ROOT??path.join(process.env.USERPROFILE??process.env.HOME,'android-sdk');
const builds=path.join(sdk,'build-tools');
const aapt=readdirSync(builds).sort((a,b)=>b.localeCompare(a,undefined,{numeric:true}))
  .map(version=>path.join(builds,version,process.platform==='win32'?'aapt.exe':'aapt')).find(existsSync);
assert(aapt,'Android aapt build tool is required for APK permission verification');
const apk=process.argv[2]??'build/app/outputs/flutter-apk/app-release.apk';
const permissions=execFileSync(aapt,['dump','permissions',apk],{encoding:'utf8'});
const allowed=new Set(['INTERNET','RECORD_AUDIO','POST_NOTIFICATIONS','RECEIVE_BOOT_COMPLETED','SCHEDULE_EXACT_ALARM','VIBRATE']
  .map(name=>'android.permission.'+name));
allowed.add('com.aliceandandy.plan_app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION');
allowed.add('com.aliceandandy.plan_app.beta.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION');
const actual=[...permissions.matchAll(/uses-permission: name='([^']+)'/g)].map(m=>m[1]);
assert(actual.includes('android.permission.INTERNET'),'APK permission output is incomplete');
for(const name of actual)assert(allowed.has(name),'Unexpected APK permission: '+name);
console.log('APK minimum-permission check passed: '+actual.length+' declared permissions, no storage/location/camera/contacts');
