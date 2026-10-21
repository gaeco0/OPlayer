// @oplayer {"api":1,"id":"cloud.gdrive","name":"Google Drive","version":"1.0.0","kind":"cloud","provider":"gdrive","hosts":["www.googleapis.com"],"authHosts":["www.googleapis.com"],"root":"root","rootTitle":"내 드라이브","oauth":{"authEndpoint":"https://accounts.google.com/o/oauth2/v2/auth","tokenEndpoint":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/drive.readonly"],"extraAuthParams":{"access_type":"offline","prompt":"consent"}}}
globalThis.plugin = {
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
