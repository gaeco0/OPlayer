// @oplayer {"hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.appdata"],"extraAuthParams":{"access_type":"offline","prompt":"consent","include_granted_scopes":"false"},"nativeAndroid":"google","requiresClientSecret":true},"settings":[],"legacySyncKey":"google","setup":{"help":"Google 계정에 로그인해 재생목록·최근 재생·이어보기를 비공개 앱 데이터 저장소에 동기화합니다. 앱에 포함된 Google 등록 정보를 사용하므로 Client ID나 Secret 입력은 필요하지 않습니다."},"api":5,"id":"sync.gdrive","name":"Google Drive 동기화","version":"1.0.1","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage"],"platforms":["android","windows","linux","macos"]}
const api = 'https://www.googleapis.com/';
globalThis.plugin = {
  async accountName() { return (await plugin.syncAccount()).name; },
  async syncAccount() { const j = await OPlayer.request(api+'drive/v3/about?fields=user(permissionId,emailAddress)'); return {id:j.user.permissionId,name:j.user.emailAddress}; },
  async syncList() {
    const files = [], seen = new Set(); let page;
    do {
      const j = await OPlayer.request(api+'drive/v3/files?spaces=appDataFolder&pageSize=100&q='+encodeURIComponent("appProperties has { key='oplayerSync' and value='1' }")+'&fields=nextPageToken,files(id,name)'+(page?'&pageToken='+encodeURIComponent(page):''));
      files.push(...j.files); page=j.nextPageToken;
      if (files.length>512 || page && seen.has(page)) throw Error('동기화 파일 목록이 너무 크거나 페이지가 반복됩니다');
      seen.add(page);
    } while(page);
    return files;
  },
  syncRead({id}) { return OPlayer.request(api+'drive/v3/files/'+encodeURIComponent(id)+'?alt=media'); },
  async syncWrite({name,device,document,id}) {
    if (id) await OPlayer.request(api+'upload/drive/v3/files/'+encodeURIComponent(id)+'?uploadType=media',{method:'PATCH',body:document});
    else {
      const content=JSON.stringify(document); let boundary;
      do { boundary='oplayer-'+Date.now()+'-'+Math.random().toString(36).slice(2); } while(content.includes(boundary));
      const metadata=JSON.stringify({name,parents:['appDataFolder'],appProperties:{oplayerSync:'1',device}});
      await OPlayer.request(api+'upload/drive/v3/files?uploadType=multipart',{method:'POST',headers:{'Content-Type':'multipart/related; boundary='+boundary},body:'--'+boundary+'\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'+metadata+'\r\n--'+boundary+'\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'+content+'\r\n--'+boundary+'--\r\n' });
    }
    return true;
  }
};
