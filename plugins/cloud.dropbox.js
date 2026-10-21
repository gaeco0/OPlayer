// @oplayer {"api":1,"id":"cloud.dropbox","name":"Dropbox","version":"1.0.0","kind":"cloud","provider":"dropbox","hosts":["api.dropboxapi.com","*.dropboxusercontent.com"],"authHosts":["api.dropboxapi.com"],"root":"","rootTitle":"Dropbox","oauth":{"authEndpoint":"https://www.dropbox.com/oauth2/authorize","tokenEndpoint":"https://api.dropboxapi.com/oauth2/token","scopes":["files.metadata.read","files.content.read","account_info.read"],"extraAuthParams":{"token_access_type":"offline"},"loopbackHost":"localhost"}}
globalThis.plugin = {
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
