// @oplayer {"hosts":["api.dropboxapi.com","*.dropboxusercontent.com","content.dropboxapi.com"],"authHosts":["api.dropboxapi.com","content.dropboxapi.com"],"oauth":{"authEndpoint":"https://www.dropbox.com/oauth2/authorize","tokenEndpoint":"https://api.dropboxapi.com/oauth2/token","scopes":["files.metadata.read","files.content.read","files.content.write","account_info.read"],"extraAuthParams":{"token_access_type":"offline"},"loopbackHost":"localhost","mobileRedirectUri":"com.oplayer.oplayer://oauth/dropbox"},"settings":[{"key":"clientId","label":"App Key","type":"text","required":true}],"setup":{"help":"Dropbox Scoped access 앱에 files.metadata.read · files.content.read · files.content.write · account_info.read 권한과 복귀 주소를 등록하세요. App folder 또는 Full Dropbox 앱에서 OPlayer Sync 폴더에 기록 JSON을 저장합니다.","consoleUrl":"https://www.dropbox.com/developers/apps","redirectUris":["com.oplayer.oplayer://oauth/dropbox","http://localhost:53682/callback"]},"api":5,"id":"sync.dropbox","name":"Dropbox 동기화","version":"1.0.0","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage"],"platforms":["android","windows","linux","macos"]}
const api='https://api.dropboxapi.com/2/';
globalThis.plugin={
  async accountName(){return (await plugin.syncAccount()).name;},
  async syncAccount(){const j=await OPlayer.request(api+'users/get_current_account',{method:'POST',body:null});return {id:j.account_id,name:j.email||j.name.display_name};},
  async _folder(){
    const result=await OPlayer.request(api+'files/create_folder_v2',{method:'POST',body:{path:'/OPlayer Sync',autorename:false},response:'raw'});
    if(result.status>=200&&result.status<300)return;
    if(result.status!==409)throw Error('Dropbox 동기화 폴더 생성 실패 (HTTP '+result.status+')');
    const existing=await OPlayer.request(api+'files/get_metadata',{method:'POST',body:{path:'/OPlayer Sync'}});
    if(existing['.tag']!=='folder')throw Error('OPlayer Sync 이름의 폴더가 필요합니다');
  },
  async syncList(){
    await plugin._folder();const files=[],seen=new Set();
    let j=await OPlayer.request(api+'files/list_folder',{method:'POST',body:{path:'/OPlayer Sync',limit:2000}});
    while(true){
      files.push(...j.entries.filter(f=>f['.tag']==='file'&&/^oplayer-sync-v1-.+\.json$/.test(f.name)).map(f=>({id:f.path_lower,name:f.name})));
      if(files.length>512)throw Error('동기화 파일이 너무 많습니다');if(!j.has_more)break;
      if(seen.has(j.cursor))throw Error('Dropbox 목록 페이지가 반복됩니다');seen.add(j.cursor);
      j=await OPlayer.request(api+'files/list_folder/continue',{method:'POST',body:{cursor:j.cursor}});
    }return files;
  },
  syncRead({id}){return OPlayer.request('https://content.dropboxapi.com/2/files/download',{method:'POST',headers:{'Dropbox-API-Arg':JSON.stringify({path:id})}});},
  async syncWrite({name,document}){
    await plugin._folder();
    const j=await OPlayer.request('https://content.dropboxapi.com/2/files/upload',{method:'POST',headers:{'Content-Type':'application/octet-stream','Dropbox-API-Arg':JSON.stringify({path:'/OPlayer Sync/'+name,mode:'overwrite',autorename:false,mute:true})},body:JSON.stringify(document)});
    if(!j.id)throw Error('Dropbox 저장 결과를 확인하지 못했습니다');return true;
  }
};
