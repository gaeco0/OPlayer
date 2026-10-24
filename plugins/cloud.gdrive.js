// @oplayer {"api":4,"id":"cloud.gdrive","name":"Google Drive","version":"1.3.0","kind":"resource","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"내 드라이브","oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive"],"extraAuthParams":{"access_type":"offline","prompt":"consent"},"nativeAndroid":"google","requiresClientSecret":true},"setup":{"nativeRegistration":"google","help":"배포 앱의 Google OAuth 등록값으로 계정을 연결합니다. Drive API와 전체 읽기·쓰기 범위 drive를 설정하세요. 기존 읽기 전용 계정은 확장앱 업데이트 후 다시 연결해야 업로드할 수 있습니다. 동기화 권한 drive.appdata는 별도로 사용합니다. 테스트 상태 인증은 7일 후 만료될 수 있습니다.","consoleUrl":"https://console.cloud.google.com/apis/credentials"},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true,"description":"배포 앱의 등록값을 기본으로 사용합니다. 직접 등록한 값으로 변경할 수 있습니다."},{"key":"clientSecret","label":"데스크톱 Client Secret","type":"password","required":true,"platforms":["windows","linux","macos"],"description":"배포 앱의 기본 ID를 사용하면 비워 둘 수 있습니다. 직접 발급한 데스크톱 ID에는 해당 Secret을 입력하세요."}],"platforms":["android","windows","linux","macos"],"capabilities":["storage"],"canSearch":true,"canUpload":true}
globalThis.plugin = {
  validateSettings() { return /^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(OPlayer.config.clientId || '') ? null : '발급받은 Google Client ID를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://www.googleapis.com/drive/v3/about?fields=user'); return j.user.emailAddress || 'Google Drive'; },
  _escape(value) { return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'"); },
  list({path}) { return plugin._files("'" + plugin._escape(path) + "' in parents and trashed=false"); },
  search({query,path}) {
    const text = query.trim();
    if (!text) return [];
    return plugin._files("'" + plugin._escape(path) + "' in parents and trashed=false and name contains '" + plugin._escape(text) + "'");
  },
  async _files(query) {
    const out = []; let page;
    do {
      let url = 'https://www.googleapis.com/drive/v3/files?q=' + encodeURIComponent(query) +
        '&pageSize=1000&orderBy=folder%2Cname&supportsAllDrives=true&includeItemsFromAllDrives=true&fields=nextPageToken%2Cfiles(id%2Cname%2CmimeType%2Csize%2CmodifiedTime%2CthumbnailLink)';
      if (page) url += '&pageToken=' + encodeURIComponent(page);
      const j = await OPlayer.request(url);
      for (const f of j.files) {
        const isDir = f.mimeType === 'application/vnd.google-apps.folder';
        if (!isDir && (f.mimeType || '').startsWith('application/vnd.google-apps')) continue;
        out.push({name:f.name,path:f.id,isDir,size:Number(f.size || 0),modified:f.modifiedTime,thumbnailUrl:f.thumbnailLink});
      }
      page = j.nextPageToken;
    } while (page);
    return out;
  },
  async upload({path,name,size,overwritePath}) {
    const matches = (await plugin.list({path})).filter(f => f.name.toLowerCase() === name.toLowerCase());
    if (matches.length > 1 || matches.some(f => f.isDir)) throw Error('같은 이름의 항목이 여러 개이거나 폴더입니다. 다른 파일명을 사용하세요');
    const existing = matches[0];
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
