// @oplayer {"api":1,"id":"cloud.onedrive","name":"OneDrive","version":"1.1.0","kind":"cloud","provider":"onedrive","hosts":["graph.microsoft.com","*.1drv.com","*.sharepoint.com","*.live.com"],"authHosts":["graph.microsoft.com"],"root":"root","rootTitle":"OneDrive","oauth":{"authEndpoint":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize","tokenEndpoint":"https://login.microsoftonline.com/common/oauth2/v2.0/token","scopes":["Files.Read","User.Read","offline_access"],"extraAuthParams":{"prompt":"select_account"},"loopbackHost":"localhost"},"setup":{"help":"Microsoft Entra에서 개인 Microsoft 계정을 포함하는 앱을 등록하고 모바일·데스크톱 플랫폼과 Files.Read · User.Read · offline_access 권한을 추가해 주세요.","consoleUrl":"https://entra.microsoft.com/","redirectUris":["com.oplayer.oplayer://oauth/onedrive","http://localhost:53682/callback"]},"settings":[{"key":"clientId","label":"Application (client) ID","type":"text","required":true}]}
globalThis.plugin = {
  validateSettings() { return /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/.test(OPlayer.config.clientId || '') ? null : '발급받은 Client ID를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://graph.microsoft.com/v1.0/me'); return j.userPrincipalName || j.displayName || 'OneDrive'; },
  async list({path}) {
    const out = []; let url = 'https://graph.microsoft.com/v1.0/me/drive/' + (path==='root' ? 'root' : 'items/' + encodeURIComponent(path)) + '/children?$top=1000&$expand=thumbnails';
    while (url) {
      const j = await OPlayer.request(url);
      for (const f of j.value) out.push({name:f.name,path:f.id,isDir:!!f.folder,size:f.size||0,modified:f.lastModifiedDateTime,thumbnailUrl:f.thumbnails?.[0]?.medium?.url});
      url = j['@odata.nextLink'];
    }
    return out;
  },
  async stream({path}) {
    const j = await OPlayer.request('https://graph.microsoft.com/v1.0/me/drive/items/' + encodeURIComponent(path) + '?$select=id,@microsoft.graph.downloadUrl');
    if (!j['@microsoft.graph.downloadUrl']) throw new Error('재생 URL을 얻지 못했습니다');
    return {url:j['@microsoft.graph.downloadUrl']};
  }
};
