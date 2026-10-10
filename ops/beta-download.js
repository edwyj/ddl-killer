(() => {
  const byId=id=>document.getElementById(id);
  let checking=false;
  async function check() {
    if(checking)return;
    checking=true;byId('error').textContent='';byId('retry').hidden=true;
    byId('status').textContent='正在获取测试安装包…';
    try {
      const response=await fetch('/api/beta/release',{credentials:'same-origin',cache:'no-store'});
      if(response.status===401) {
        byId('ready').hidden=true;byId('login').hidden=false;byId('status').textContent='登录后即可下载。';return;
      }
      const info=await response.json();
      if(!response.ok)throw new Error(info.error || '暂时无法获取安装包，请稍后重试。');
      byId('login').hidden=true;byId('ready').hidden=false;byId('status').textContent='测试安装包已准备好。';
      byId('version').textContent='当前版本 '+info.version;
      byId('size').textContent=(info.bytes/1024/1024).toFixed(1);
    }catch(error) {
      byId('status').textContent='';byId('error').textContent=error.message || '网络连接不稳定，请重试。';byId('retry').hidden=false;
    }finally{checking=false;}
  }
  byId('login').addEventListener('submit',async event=>{
    event.preventDefault();const button=byId('submit');if(button.disabled)return;
    button.disabled=true;button.textContent='正在登录…';byId('error').textContent='';
    try {
      const response=await fetch('/api/auth/login',{method:'POST',credentials:'same-origin',
        headers:{'Content-Type':'application/json'},body:JSON.stringify({username:byId('username').value.trim(),password:byId('password').value,client:'web'})});
      const result=await response.json();
      if(!response.ok)throw new Error(result.error || '登录未成功，请检查账号和密码。');
      byId('password').value='';await check();
    }catch(error){byId('error').textContent=error.message || '网络连接不稳定，请重试。';}
    finally{button.disabled=false;button.textContent='登录并获取安装包';}
  });
  byId('retry').addEventListener('click',check);
  byId('download').addEventListener('click',()=>{byId('status').textContent='下载即将开始，如未开始，请确认登录状态后重试。';byId('retry').hidden=false;});
  check();
})();
