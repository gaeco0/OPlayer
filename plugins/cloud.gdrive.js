// @oplayer {"api":5,"id":"cloud.gdrive","name":"Google Drive","version":"1.6.0","kind":"resource","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"내 드라이브","oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.readonly","https://www.googleapis.com/auth/drive.file"],"extraAuthParams":{"access_type":"offline","prompt":"consent","include_granted_scopes":"false"},"nativeAndroid":"google","requiresClientSecret":true},"setup":{"nativeRegistration":"google","help":"Drive API 사용 설정 후 drive.readonly와 drive.file을 등록하세요. 기존 Drive 파일·폴더는 읽기 전용으로 탐색·재생합니다. 업로드 저장 위치를 선택하면 내 드라이브에 OPlayer 전용 폴더를 만들거나 재사용하며, 앱에 쓰기 권한이 있는 파일만 덮어씁니다. 기존 임의 파일의 수정·삭제는 제공하지 않습니다. Google Picker는 사용하지 않습니다. 권한 구성이 바뀌므로 계정을 다시 연결하세요. 동기화는 별도 drive.appdata입니다. drive.readonly는 Google 제한된 범위 검증 대상입니다.","consoleUrl":"https://console.cloud.google.com/apis/credentials"},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true,"description":"배포 앱의 등록값을 기본으로 사용합니다. 직접 등록한 값으로 변경할 수 있습니다."},{"key":"clientSecret","label":"데스크톱 Client Secret","type":"password","required":true,"platforms":["windows","linux","macos"],"description":"배포 앱의 기본 ID를 사용하면 비워 둘 수 있습니다. 직접 발급한 데스크톱 ID에는 해당 Secret을 입력하세요."}],"platforms":["android","windows","linux","macos"],"capabilities":["storage"],"canSearch":true,"canUpload":true,"requiresHost":["googleDriveReadUpload","fixedUploadRoot"],"uploadRoot":{"title":"OPlayer"}}
globalThis.plugin = {
  validateSettings() { return /^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(OPlayer.config.clientId || '') ? null : '발급받은 Google Client ID를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://www.googleapis.com/drive/v3/about?fields=user'); return j.user.emailAddress || 'Google Drive'; },
  _escape(value) { return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'"); },
  list({path}) { return plugin._files(plugin._folderQuery(path)); },
  _folderQuery(path) { return "'" + plugin._escape(path) + "' in parents and trashed=false"; },
  search({query,path}) {
    const text = query.trim();
    if (!text) return [];
    return plugin._files(plugin._folderQuery(path) + " and name contains '" + plugin._escape(text) + "'");
  },
  async _files(query) {
    const out = []; let page;
    do {
      let url = 'https://www.googleapis.com/drive/v3/files?q=' + encodeURIComponent(query) +
        '&pageSize=1000&orderBy=folder%2Cname&supportsAllDrives=true&includeItemsFromAllDrives=true&fields=nextPageToken%2Cfiles(id%2Cname%2CmimeType%2Csize%2CmodifiedTime%2CthumbnailLink%2CisAppAuthorized)';
      if (page) url += '&pageToken=' + encodeURIComponent(page);
      const j = await OPlayer.request(url);
      for (const f of j.files) {
        const isDir = f.mimeType === 'application/vnd.google-apps.folder';
        if (!isDir && (f.mimeType || '').startsWith('application/vnd.google-apps')) continue;
        out.push({name:f.name,path:f.id,isDir,size:Number(f.size || 0),modified:f.modifiedTime,thumbnailUrl:f.thumbnailLink,isAppAuthorized:f.isAppAuthorized === true});
      }
      page = j.nextPageToken;
    } while (page);
    return out;
  },
  _ownedFolder(f) { return f && f.mimeType === 'application/vnd.google-apps.folder' && !f.trashed && f.isAppAuthorized === true && f.appProperties && f.appProperties.oplayerUploadFolder === 'v1'; },
  async uploadRoot() {
    const q = "'root' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false and appProperties has { key='oplayerUploadFolder' and value='v1' }";
    let page;
    do {
      const j = await OPlayer.request('https://www.googleapis.com/drive/v3/files?q=' + encodeURIComponent(q) +
        '&pageSize=1000&orderBy=createdTime&fields=nextPageToken,files(id,mimeType,appProperties,isAppAuthorized,trashed)' + (page ? '&pageToken=' + encodeURIComponent(page) : ''));
      const folder = (j.files || []).find(plugin._ownedFolder);
      if (folder) return folder.id;
      page = j.nextPageToken;
    } while (page);
    const created = await OPlayer.request('https://www.googleapis.com/drive/v3/files?fields=id', {
      method:'POST', body:{name:'OPlayer',mimeType:'application/vnd.google-apps.folder',parents:['root'],appProperties:{oplayerUploadFolder:'v1'}}
    });
    if (!created || typeof created.id !== 'string' || !created.id) throw Error('OPlayer 업로드 폴더를 만들지 못했습니다');
    return created.id;
  },
  async _uploadFolder(path) {
    if (!path || path === 'root' || path === '/') return plugin.uploadRoot();
    const folder = await OPlayer.request('https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(path) + '?fields=id,mimeType,appProperties,isAppAuthorized,trashed');
    if (!plugin._ownedFolder(folder)) throw Error('저장 위치에서 OPlayer 전용 업로드 폴더를 다시 선택해 주세요');
    return folder.id;
  },
  async upload({path,name,size,overwritePath}) {
    path = await plugin._uploadFolder(path);
    const matches = (await plugin._files(plugin._folderQuery(path))).filter(f => f.name.toLowerCase() === name.toLowerCase());
    if (matches.length > 1 || matches.some(f => f.isDir)) throw Error('같은 이름의 항목이 여러 개이거나 폴더입니다. 다른 파일명을 사용하세요');
    const existing = matches[0];
    if (existing && !existing.isAppAuthorized) throw Error('이 기존 파일에는 앱의 쓰기 권한이 없습니다. 다른 이름으로 저장해 주세요');
    if (overwritePath && (!existing || existing.path !== overwritePath)) throw Error('덮어쓰기 대상이 바뀌었습니다. 파일 목록을 새로고침하고 다시 확인하세요');
    if (existing && existing.path !== overwritePath) throw Error('같은 이름의 파일이 있습니다. 덮어쓰기를 확인하거나 다른 이름을 사용하세요');
    const url = 'https://www.googleapis.com/upload/drive/v3/files' + (existing ? '/' + encodeURIComponent(existing.path) : '') +
      '?uploadType=resumable&supportsAllDrives=true&fields=id';
    const headers = await OPlayer.request(url, {
      method:existing ? 'PATCH' : 'POST', response:'headers',
      headers:{'Content-Type':'application/json; charset=UTF-8','X-Upload-Content-Type':'application/octet-stream','X-Upload-Content-Length':String(size)},
      body:existing ? {name} : {name,parents:[path]}
    });
    if (!headers.location) throw Error('업로드 세션 주소가 없습니다');
    return {protocol:'http-content-range',url:headers.location};
  },
  uploadComplete({response}) {
    if (!response || typeof response.id !== 'string' || !response.id) throw Error('업로드된 파일 ID가 없습니다');
    return response.id;
  },
  stream({path}) { return {url:'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(path) + '?alt=media&supportsAllDrives=true',authenticated:true}; }
};
