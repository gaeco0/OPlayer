// @oplayer {"hosts":["api.box.com","upload.box.com","*.boxcloud.com"],"authHosts":["api.box.com","upload.box.com"],"oauth":{"authEndpoint":"https://account.box.com/api/oauth2/authorize","tokenEndpoint":"https://api.box.com/oauth2/token","scopes":[],"requiresClientSecret":true,"pkce":false,"loopbackHost":"localhost","help":"Box Developer Console에서 OAuth 2.0 앱을 만들고 파일·폴더 읽기 권한을 켜세요. 아래 localhost 복귀 주소를 등록하고 Client ID와 Client Secret을 입력하세요. 모바일도 시스템 브라우저에서 로그인하고 완료 후 앱으로 돌아오세요. Secret과 토큰은 기기 보안 저장소에 저장합니다. 조직 정책에 따라 관리자 승인이 필요할 수 있습니다.","consoleUrl":"https://app.box.com/developers/console","loopbackOnMobile":true},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true},{"key":"clientSecret","label":"Client Secret","type":"password","required":true}],"setup":{"help":"Box Developer Console에서 OAuth 앱과 파일·폴더 읽기/쓰기 권한을 등록하세요. 내 파일의 OPlayer Sync 폴더에 재생 기록 JSON을 저장합니다. Client ID와 Secret은 이 확장앱 설정에 입력합니다.","consoleUrl":"https://app.box.com/developers/console","redirectUris":["http://localhost:53682/callback"]},"api":5,"id":"sync.box","name":"Box 동기화","version":"1.0.0","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage"],"platforms":["android","windows","linux","macos"]}
const api='https://api.box.com/2.0/';
globalThis.plugin={
  async accountName(){return (await plugin.syncAccount()).name;},
  async syncAccount(){const j=await OPlayer.request(api+'users/me?fields=id,login,name');return {id:j.id,name:j.login||j.name||'Box'};},
  async _folder(){
    const result=await OPlayer.request(api+'folders',{method:'POST',body:{name:'OPlayer Sync',parent:{id:'0'}},response:'raw'});
    const j=JSON.parse(result.body);
    if(result.status>=200&&result.status<300)return j.id;
    const conflicts=j.context_info&&j.context_info.conflicts;
    const folder=(Array.isArray(conflicts)?conflicts:[conflicts]).find(f=>f&&f.type==='folder'&&f.name==='OPlayer Sync');
    if(result.status===409&&folder)return folder.id;
    throw Error('Box 동기화 폴더를 준비하지 못했습니다 (HTTP '+result.status+')');
  },
  async syncList(){
    const folder=await plugin._folder(),files=[],seen=new Set();let marker='';
    do{
      const j=await OPlayer.request(api+'folders/'+encodeURIComponent(folder)+'/items?usemarker=true&limit=1000&fields=id,type,name'+(marker?'&marker='+encodeURIComponent(marker):''));
      files.push(...j.entries.filter(f=>f.type==='file'&&/^oplayer-sync-v1-.+\.json$/.test(f.name)).map(f=>({id:f.id,name:f.name})));
      marker=j.next_marker||'';
      if(files.length>512||marker&&seen.has(marker))throw Error('Box 동기화 목록이 너무 크거나 페이지가 반복됩니다');seen.add(marker);
    }while(marker);return files;
  },
  async syncRead({id}){
    const j=await OPlayer.request(api+'files/'+encodeURIComponent(id)+'/content',{response:'redirect'});
    return OPlayer.request(j.url,{authenticated:false});
  },
  async syncWrite({name,document,id}){
    const folder=await plugin._folder(),content=JSON.stringify(document);let boundary;
    do{boundary='oplayer-'+Date.now()+'-'+Math.random().toString(36).slice(2);}while(content.includes(boundary));
    const attributes=JSON.stringify(id?{name}:{name,parent:{id:folder}});
    const result=await OPlayer.request('https://upload.box.com/api/2.0/files/'+(id?encodeURIComponent(id)+'/':'')+'content',{
      method:'POST',headers:{'Content-Type':'multipart/form-data; boundary='+boundary},
      body:'--'+boundary+'\r\nContent-Disposition: form-data; name="attributes"\r\n\r\n'+attributes+'\r\n--'+boundary+'\r\nContent-Disposition: form-data; name="file"; filename="'+name+'"\r\nContent-Type: application/json\r\n\r\n'+content+'\r\n--'+boundary+'--\r\n' });
    if(!result.entries||!result.entries[0]||!result.entries[0].id)throw Error('Box 저장 결과를 확인하지 못했습니다');return true;
  }
};
