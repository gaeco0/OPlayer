// @oplayer {"api":4,"id":"resource.peertube","name":"PeerTube","version":"1.0.0","kind":"resource","capabilities":["storage"],"hosts":[],"authHosts":[],"networkSettings":["endpoint"],"authSettings":["endpoint"],"root":"root","rootTitle":"PeerTube 동영상","auth":{"type":"script"},"canSearch":true,"features":["인스턴스 연결","공개 영상 탐색","선택적 사용자 로그인","영상 검색·재생"],"description":"사용자 지정 PeerTube 인스턴스의 공개·내 영상 탐색, 검색과 HTTP/HLS 재생","setup":{"help":"PeerTube HTTPS 인스턴스 기본 주소를 입력하세요. 공개 영상은 사용자 이름 없이 연결합니다. 내 영상·비공개 영상은 로그인 계정을 입력하세요. 재생은 HTTP/HLS로 하며 P2P·영상 업로드·비밀번호 보호 영상·2단계 인증 로그인은 지원하지 않습니다.","consoleUrl":"https://docs.joinpeertube.org/api/rest-getting-started"},"settings":[{"key":"displayName","label":"연결 이름 (선택)","type":"text"},{"key":"endpoint","label":"PeerTube 인스턴스 URL (HTTPS)","type":"url","required":true},{"key":"username","label":"사용자 이름 (공개 영상만 이용하면 비움)","type":"text"},{"key":"password","label":"비밀번호 (로그인할 때 필요)","type":"password"}]}
const ptBase = () => OPlayer.config.endpoint.trim().replace(/\/+$/, '');
const ptLoggedIn = () => !!OPlayer.config.username?.trim();
const ptHeaders = () => ptLoggedIn() ? {Authorization:OPlayer.secret('sessionToken',{prefix:'Bearer '})} : {};
const ptApi = (path, options = {}) => OPlayer.request(ptBase() + '/api/v1' + path, {headers:ptHeaders(), ...options});
const ptId = id => {
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw Error('PeerTube 동영상 ID가 올바르지 않습니다');
  return encodeURIComponent(id);
};
async function ptVideos(path, query = {}) {
  const out = [];
  for (let start = 0; ; ) {
    const j = await ptApi(path, {query:{start:String(start),count:'100',sort:'-publishedAt',...query}});
    if (!Array.isArray(j.data)) throw Error('PeerTube 목록 응답이 올바르지 않습니다');
    for (const v of j.data) out.push({name:v.name + (v.name.toLowerCase().endsWith('.mp4') ? '' : '.mp4'),
      path:String(v.uuid || v.id), isDir:false, modified:v.publishedAt || v.createdAt});
    start += j.data.length;
    if (!j.data.length || start >= j.total || j.data.length < 100 && j.total == null) return out;
    if (start >= 5000) throw Error('목록이 너무 큽니다. 검색으로 범위를 좁혀 주세요');
  }
}
globalThis.plugin = {
  validateSettings() { return /^https:\/\/[^/?#]+(?:\/[^?#]*)?$/.test(OPlayer.config.endpoint || '') ? null : 'HTTPS 인스턴스 기본 주소를 입력하세요'; },
  async authenticate() {
    if (!ptLoggedIn()) return null;
    const c = await OPlayer.request(ptBase() + '/api/v1/oauth-clients/local');
    const j = await OPlayer.request(ptBase() + '/api/v1/users/token', {method:'POST', bodyFields:{
      client_id:c.client_id,client_secret:c.client_secret,grant_type:'password',username:OPlayer.config.username.trim(),password:OPlayer.secret('password')
    }});
    if (!j.access_token || !j.refresh_token) throw Error('PeerTube 로그인 응답을 확인해 주세요');
    return {sessionToken:j.access_token,sessionRefresh:j.refresh_token};
  },
  async refresh() {
    const c = await OPlayer.request(ptBase() + '/api/v1/oauth-clients/local');
    const j = await OPlayer.request(ptBase() + '/api/v1/users/token', {method:'POST', bodyFields:{
      client_id:c.client_id,client_secret:c.client_secret,grant_type:'refresh_token',refresh_token:OPlayer.secret('sessionRefresh')
    }});
    if (!j.access_token || !j.refresh_token) throw Error('PeerTube 계정을 다시 연결해 주세요');
    return {sessionToken:j.access_token,sessionRefresh:j.refresh_token};
  },
  async accountName() {
    if (ptLoggedIn()) return 'PeerTube · ' + (await ptApi('/users/me')).username;
    const j = await ptApi('/config');
    return 'PeerTube · ' + (j.instance?.name || ptBase());
  },
  async list({path}) {
    if (path === 'mine') {
      if (!ptLoggedIn()) throw Error('내 영상은 로그인이 필요합니다');
      return ptVideos('/users/me/videos');
    }
    if (path !== 'root') throw Error('알 수 없는 PeerTube 폴더입니다');
    const rows = await ptVideos('/videos');
    if (ptLoggedIn()) rows.unshift({name:'내 영상',path:'mine',isDir:true});
    return rows;
  },
  async search({query, path}) {
    if (!query.trim()) return [];
    if (path === 'mine') {
      const text = query.trim().toLowerCase();
      return (await plugin.list({path})).filter(v => v.name.toLowerCase().includes(text));
    }
    if (path !== 'root') throw Error('알 수 없는 PeerTube 폴더입니다');
    return ptVideos('/search/videos', {search:query.trim()});
  },
  async stream({path}) {
    const id = ptId(path), j = await ptApi('/videos/' + id);
    if (Number(j.privacy?.id) === 5) throw Error('비밀번호 보호 영상은 지원하지 않습니다');
    const files = [...(j.files || [])].filter(f => f.fileUrl && f.hasAudio !== false && f.hasVideo !== false);
    files.sort((a,b) => Number(b.resolution?.id || 0) - Number(a.resolution?.id || 0));
    const url = files[0]?.fileUrl || j.streamingPlaylists?.find(p => p.playlistUrl)?.playlistUrl;
    if (!url || !url.startsWith('https://')) throw Error('HTTPS 재생 주소가 없습니다. 아직 변환 중인 영상일 수 있습니다');
    if (Number(j.privacy?.id) >= 3) {
      const t = await ptApi('/videos/' + id + '/token', {method:'POST',headers:ptHeaders()});
      if (!t.files?.token) throw Error('비공개 영상의 재생 토큰을 얻지 못했습니다');
      return {url:url + (url.includes('?') ? '&' : '?') + 'videoFileToken=' + encodeURIComponent(t.files.token) + '&reinjectVideoFileToken=true'};
    }
    return {url};
  }
};
