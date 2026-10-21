// @oplayer {"api":2,"id":"cloud.box","name":"Box","version":"1.0.0","kind":"cloud","hosts":["api.box.com"],"authHosts":["api.box.com"],"root":"0","rootTitle":"Box","oauth":{"authEndpoint":"https://account.box.com/api/oauth2/authorize","tokenEndpoint":"https://api.box.com/oauth2/token","scopes":[],"requiresClientSecret":true,"pkce":false,"loopbackHost":"localhost","help":"Box Developer Console에서 OAuth 2.0 앱을 만들고 파일·폴더 읽기 권한을 켜세요. 아래 localhost 복귀 주소를 등록하고 Client ID와 Client Secret을 입력하세요. 모바일도 시스템 브라우저에서 로그인하고 완료 후 앱으로 돌아오세요. Secret과 토큰은 기기 보안 저장소에 저장합니다. 조직 정책에 따라 관리자 승인이 필요할 수 있습니다.","consoleUrl":"https://app.box.com/developers/console","loopbackOnMobile":true}}
const boxApi = 'https://api.box.com/2.0/';
globalThis.plugin = {
  async accountName() { const j = await OPlayer.request(boxApi + 'users/me'); return j.login || j.name || 'Box'; },
  async list({path}) {
    const out = [], seen = new Set(); let marker = '';
    do {
      const j = await OPlayer.request(boxApi + 'folders/' + encodeURIComponent(path) + '/items?usemarker=true&limit=1000&fields=id,type,name,size,modified_at' + (marker ? '&marker=' + encodeURIComponent(marker) : ''));
      for (const f of j.entries) if (f.type === 'file' || f.type === 'folder') out.push({name:f.name,path:f.id,isDir:f.type === 'folder',size:f.size || 0,modified:f.modified_at});
      marker = j.next_marker || '';
      if (marker && seen.has(marker)) throw new Error('Box 다음 페이지 정보가 반복됩니다');
      seen.add(marker);
    } while (marker);
    return out;
  },
  async stream({path, refresh}) {
    const url = boxApi + 'files/' + encodeURIComponent(path);
    const info = refresh ? {} : await OPlayer.request(url + '?fields=id,name,size');
    const j = await OPlayer.request(url + '/content', {response:'redirect'});
    return {url:j.url,size:info.size,name:info.name,refreshEachRequest:true};
  }
};
