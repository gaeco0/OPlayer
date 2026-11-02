// @oplayer {"api":5,"id":"cloud.gdrive","name":"Google Drive","version":"1.5.0","kind":"resource","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"OPlayer 파일","oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.file"],"extraAuthParams":{"access_type":"offline","prompt":"consent","include_granted_scopes":"false","trigger_onepick":"true","allow_multiple":"true"},"nativeAndroid":"google","requiresClientSecret":true},"setup":{"nativeRegistration":"google","help":"Drive API와 Google Picker API를 사용 설정하고 drive.file 범위를 등록하세요. 계정 연결 시 Google 파일 선택기에서 영상과 자막을 함께 선택하면 OPlayer 파일 목록에 표시됩니다. 전체 Drive 접근은 요청하지 않습니다. Android의 파일 선택은 Picker 지원 앱 업데이트가 필요합니다. 동기화는 별도 drive.appdata 권한입니다.","consoleUrl":"https://console.cloud.google.com/apis/credentials"},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true,"description":"배포 앱의 등록값을 기본으로 사용합니다. 직접 등록한 값으로 변경할 수 있습니다."},{"key":"clientSecret","label":"데스크톱 Client Secret","type":"password","required":true,"platforms":["windows","linux","macos"],"description":"배포 앱의 기본 ID를 사용하면 비워 둘 수 있습니다. 직접 발급한 데스크톱 ID에는 해당 Secret을 입력하세요."}],"platforms":["android","windows","linux","macos"],"capabilities":["storage"],"canSearch":true,"canUpload":true,"requiresHost":["googlePicker"]}
globalThis.plugin = {
  validateSettings() { return /^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(OPlayer.config.clientId || '') ? null : '발급받은 Google Client ID를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://www.googleapis.com/drive/v3/about?fields=user'); return j.user.emailAddress || 'Google Drive'; },
  _escape(value) { return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'"); },
  list({path}) { return plugin._files(plugin._folderQuery(path)); },
  _folderQuery(path, childrenOnly = false) { return path === 'root' && !childrenOnly ? 'trashed=false' : "'" + plugin._escape(path) + "' in parents and trashed=false"; },
  search({query,path}) {
    const text = query.trim();
    if (!text) return [];
    return plugin._files(plugin._folderQuery(path) + " and name contains '" + plugin._escape(text) + "'");
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
    const matches = (await plugin._files(plugin._folderQuery(path, true))).filter(f => f.name.toLowerCase() === name.toLowerCase());
    if (matches.length > 1 || matches.some(f => f.isDir)) throw Error('같은 이름의 항목이 여러 개이거나 폴더입니다. 다른 파일명을 사용하세요');
    const existing = matches[0];
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
