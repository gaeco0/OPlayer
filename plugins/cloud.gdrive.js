// @oplayer {"api":4,"id":"cloud.gdrive","name":"Google Drive","version":"1.1.2","kind":"resource","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"내 드라이브","oauth":{"clientIdSource":"app.google","authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.readonly"],"extraAuthParams":{"access_type":"offline","prompt":"consent"},"nativeAndroid":"google","requiresClientSecret":true},"setup":{"nativeRegistration":"google","help":"Google Drive API와 OAuth 동의 화면의 drive.readonly 권한·테스트 사용자를 설정하세요. Android는 패키지·SHA-1로 Android OAuth 클라이언트를, 데스크톱은 데스크톱 OAuth 클라이언트를 등록하세요. 테스트 모드 인증은 7일 후 만료될 수 있습니다.","consoleUrl":"https://console.cloud.google.com/apis/credentials"},"settings":[{"key":"clientId","label":"OAuth Client ID","type":"text","required":true},{"key":"clientSecret","label":"데스크톱 Client Secret","type":"password","required":true,"platforms":["windows","linux","macos"]}],"platforms":["android","windows","linux","macos"],"capabilities":["storage"]}
globalThis.plugin = {
  validateSettings() { return /^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$/.test(OPlayer.config.clientId || '') ? null : '발급받은 Google Client ID를 확인해 주세요'; },
  async accountName() { const j = await OPlayer.request('https://www.googleapis.com/drive/v3/about?fields=user'); return j.user.emailAddress || 'Google Drive'; },
  async list({path}) {
    const out = []; let page;
    do {
      const query = "'" + path.replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "' in parents and trashed=false";
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
