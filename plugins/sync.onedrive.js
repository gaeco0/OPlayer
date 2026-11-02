// @oplayer {"hosts":["graph.microsoft.com","*.1drv.com","*.sharepoint.com","*.live.com"],"authHosts":["graph.microsoft.com"],"oauth":{"authEndpoint":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize","tokenEndpoint":"https://login.microsoftonline.com/common/oauth2/v2.0/token","scopes":["Files.ReadWrite.AppFolder","User.Read","offline_access"],"extraAuthParams":{"prompt":"select_account"},"loopbackHost":"localhost","mobileRedirectUri":"com.oplayer.oplayer://oauth/onedrive"},"settings":[{"key":"clientId","label":"Application (client) ID","type":"text","required":true}],"setup":{"help":"Microsoft Entra에서 Files.ReadWrite.AppFolder · User.Read · offline_access 권한과 모바일/데스크톱 복귀 주소를 등록하세요. OneDrive 앱 전용 폴더에 재생 기록 JSON을 저장합니다.","consoleUrl":"https://entra.microsoft.com/","redirectUris":["com.oplayer.oplayer://oauth/onedrive","http://localhost:53682/callback"]},"api":5,"id":"sync.onedrive","name":"OneDrive 동기화","version":"1.0.0","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage"],"platforms":["android","windows","linux","macos"]}
const api='https://graph.microsoft.com/v1.0/me/';
globalThis.plugin={
  async accountName(){return (await plugin.syncAccount()).name;},
  async syncAccount(){const j=await OPlayer.request(api+'?$select=id,displayName,userPrincipalName');return {id:j.id,name:j.userPrincipalName||j.displayName||'OneDrive'};},
  async syncList(){
    const files=[],seen=new Set();let url=api+'drive/special/approot/children?$select=id,name,file&$top=200';
    while(url){
      if(seen.has(url))throw Error('동기화 목록 페이지가 반복됩니다');seen.add(url);
      const j=await OPlayer.request(url);
      files.push(...j.value.filter(f=>f.file&&/^oplayer-sync-v1-.+\.json$/.test(f.name)).map(f=>({id:f.id,name:f.name})));
      if(files.length>512)throw Error('동기화 파일이 너무 많습니다');url=j['@odata.nextLink'];
    }return files;
  },
  async syncRead({id}){
    const j=await OPlayer.request(api+'drive/items/'+encodeURIComponent(id)+'?$select=id,@microsoft.graph.downloadUrl');
    if(!j['@microsoft.graph.downloadUrl'])throw Error('동기화 다운로드 주소가 없습니다');
    return OPlayer.request(j['@microsoft.graph.downloadUrl'],{authenticated:false});
  },
  async syncWrite({name,document}){
    await OPlayer.request(api+'drive/special/approot:/'+encodeURIComponent(name)+':/content',{method:'PUT',body:document});return true;
  }
};
