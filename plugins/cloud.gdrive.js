// @oplayer {"api":4,"id":"cloud.gdrive","name":"Google Drive","version":"1.2.0","kind":"resource","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"내 드라이브","oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.readonly"],"extraAuthParams":{"access_type":"offline","prompt":"consent"},"nativeAndroid":"google","requiresClientSecret":true},"setup":{"nativeRegistration":"google","help":"앱에 Google OAuth 등록값이 포함되어 있으면 바로 계정을 연결할 수 있습니다. 아래 등록값은 직접 발급한 클라이언트로 변경할 때 사용합니다. 자체 빌드는 Drive API와 drive.readonly 권한을 설정하세요. 테스트 상태 인증은 7일 후 만료될 수 있습니다.","consoleUrl":"https://console.cloud.google.com/apis/credentials"},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true,"description":"배포 앱의 등록값을 기본으로 사용합니다. 직접 등록한 값으로 변경할 수 있습니다."},{"key":"clientSecret","label":"데스크톱 Client Secret","type":"password","required":true,"platforms":["windows","linux","macos"],"description":"배포 앱의 기본 ID를 사용하면 비워 둘 수 있습니다. 직접 발급한 데스크톱 ID에는 해당 Secret을 입력하세요."}],"platforms":["android","windows","linux","macos"],"capabilities":["storage"],"canSearch":true}
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
  stream({path}) { return {url:'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(path) + '?alt=media&supportsAllDrives=true',authenticated:true}; }
};
