// @oplayer {"api":4,"id":"cloud.mybox","name":"네이버 MYBOX","version":"1.1.1","kind":"resource","hosts":["open-api.mybox.naver.com"],"authHosts":["open-api.mybox.naver.com"],"root":"root","rootTitle":"MYBOX","auth":{"type":"bearer","help":"MYBOX PC 웹 → 설정 → 계정 및 개인 액세스 토큰 관리에서 토큰을 생성해 입력하세요. 토큰이 만료되면 새 토큰으로 다시 연결해야 합니다. 공식 API는 암호 폴더·공유받은 폴더를 지원하지 않습니다.","consoleUrl":"https://developers.mybox.naver.com/getting-started"},"setup":{"help":"MYBOX PC 웹 → 설정 → 계정 및 개인 액세스 토큰 관리에서 토큰을 생성해 입력하세요. 토큰이 만료되면 새 토큰으로 다시 연결해야 합니다. 공식 API는 암호 폴더·공유받은 폴더를 지원하지 않습니다.","consoleUrl":"https://developers.mybox.naver.com/getting-started"},"settings":[{"key":"displayName","label":"연결 이름 (선택)","type":"text"},{"key":"accessToken","label":"개인 액세스 토큰 (PAT)","type":"password","required":true}],"capabilities":["storage"]}
const myboxApi = 'https://open-api.mybox.naver.com/v1/drive/';
globalThis.plugin = {
  async accountName() { await OPlayer.request(myboxApi + 'storage'); return '네이버 MYBOX'; },
  async list({path}) {
    const base = myboxApi + (path === 'root' ? 'resources' : 'folders/' + encodeURIComponent(path) + '/resources');
    const out = [], seen = new Set(); let cursor = '';
    do {
      const j = await OPlayer.request(base + '?count=1000' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''));
      for (const f of j.resources) out.push({name:f.name, path:f.resourceId, isDir:f.type === 'folder', size:f.size || 0, modified:f.modifiedAt});
      cursor = j.responseMetaData?.nextCursor || '';
      if (cursor && seen.has(cursor)) throw new Error('MYBOX 다음 페이지 정보가 반복됩니다');
      seen.add(cursor);
    } while (cursor);
    return out;
  },
  async stream({path, refresh}) {
    const info = refresh ? {} : await OPlayer.request(myboxApi + 'resources/' + encodeURIComponent(path));
    const j = await OPlayer.request(myboxApi + 'files/' + encodeURIComponent(path) + '/download');
    if (!j.downloadUrl) throw new Error('MYBOX 다운로드 URL을 얻지 못했습니다');
    return {url:j.downloadUrl, size:info.size, name:info.name, refreshEachRequest:true};
  }
};
