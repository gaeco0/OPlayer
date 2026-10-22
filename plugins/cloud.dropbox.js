// @oplayer {"api":4,"id":"cloud.dropbox","name":"Dropbox","version":"1.1.1","kind":"resource","provider":"dropbox","hosts":["api.dropboxapi.com","*.dropboxusercontent.com"],"authHosts":["api.dropboxapi.com"],"root":"","rootTitle":"Dropbox","oauth":{"authEndpoint":"https://www.dropbox.com/oauth2/authorize","tokenEndpoint":"https://api.dropboxapi.com/oauth2/token","scopes":["files.metadata.read","files.content.read","account_info.read"],"extraAuthParams":{"token_access_type":"offline"},"loopbackHost":"localhost"},"setup":{"help":"Dropbox 개발자 콘솔에서 Scoped access · Full Dropbox 앱을 만들고 파일 목록·내용 읽기와 계정 정보 읽기 권한을 켜 주세요.","consoleUrl":"https://www.dropbox.com/developers/apps","redirectUris":["com.oplayer.oplayer://oauth/dropbox","http://localhost:53682/callback"]},"settings":[{"key":"clientId","label":"App Key","type":"text","required":true}],"capabilities":["storage"]}
globalThis.plugin = {
  validateSettings() { return /^[A-Za-z0-9]+$/.test(OPlayer.config.clientId || '') ? null : '발급받은 App Key를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://api.dropboxapi.com/2/users/get_current_account', {method:'POST',body:null}); return j.email || 'Dropbox'; },
  async list({path}) {
    const out = [];
    let j = await OPlayer.request('https://api.dropboxapi.com/2/files/list_folder', {method:'POST',body:{path,limit:2000}});
    while (true) {
      for (const f of j.entries) {
        if (!['file','folder'].includes(f['.tag'])) continue;
        out.push({name:f.name,path:f.path_lower,isDir:f['.tag']==='folder',size:f.size||0,modified:f.server_modified});
      }
      if (!j.has_more) break;
      j = await OPlayer.request('https://api.dropboxapi.com/2/files/list_folder/continue', {method:'POST',body:{cursor:j.cursor}});
    }
    return out;
  },
  async stream({path}) { const j = await OPlayer.request('https://api.dropboxapi.com/2/files/get_temporary_link', {method:'POST',body:{path}}); return {url:j.link}; }
};
