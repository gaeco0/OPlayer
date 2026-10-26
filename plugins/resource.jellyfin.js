// @oplayer {"api":4,"id":"resource.jellyfin","name":"Jellyfin","version":"1.0.0","kind":"resource","capabilities":["storage"],"hosts":[],"authHosts":[],"networkSettings":["endpoint"],"authSettings":["endpoint"],"root":"root","rootTitle":"Jellyfin 라이브러리","auth":{"type":"script"},"canSearch":true,"features":["사용자 로그인","라이브러리·폴더 탐색","영상·음악 검색","원본 미디어 재생"],"description":"사용자 지정 Jellyfin 서버의 라이브러리·영상·음악 탐색과 검색·원본 재생","setup":{"help":"Jellyfin의 HTTPS 서버 주소와 사용자 계정을 입력하세요. /jellyfin 같은 기본 경로도 지원합니다. HTTP 전용 LAN 서버는 HTTPS 리버스 프록시가 필요합니다. 원본 스트림을 재생하며 서버 트랜스코딩·Live TV·서버 시청 기록 동기화는 지원하지 않습니다. 재생 시작 때 로그인 토큰을 새로 발급받습니다.","consoleUrl":"https://jellyfin.org/docs/general/networking/"},"settings":[{"key":"displayName","label":"연결 이름 (선택)","type":"text"},{"key":"endpoint","label":"Jellyfin 서버 URL (HTTPS)","type":"url","required":true},{"key":"username","label":"사용자 이름","type":"text","required":true},{"key":"password","label":"비밀번호","type":"password","required":true},{"key":"deviceId","label":"기기 식별 이름","type":"text","default":"oplayer","description":"여러 기기에서 연결하면 서로 다른 이름을 사용하세요."}]}
const jfBase = () => OPlayer.config.endpoint.trim().replace(/\/+$/, '');
const jfId = path => {
  const match = /^(folder|video|audio):([a-fA-F0-9-]+)$/.exec(path);
  if (!match) throw Error('Jellyfin 항목 ID가 올바르지 않습니다');
  return encodeURIComponent(match[2]);
};
const jfHeaders = () => ({'X-Emby-Token':OPlayer.secret('sessionToken')});
const jfUser = () => OPlayer.request(jfBase() + '/Users/Me', {headers:jfHeaders()});
async function jfLogin() {
  const device = await OPlayer.crypto.hash('sha256', String(OPlayer.config.deviceId || 'oplayer'));
  const j = await OPlayer.request(jfBase() + '/Users/AuthenticateByName', {
    method:'POST',
    headers:{Authorization:'MediaBrowser Client="OPlayer", Device="OPlayer", DeviceId="' + device + '", Version="1.0.0"'},
    body:{Username:OPlayer.config.username.trim(), Pw:OPlayer.secret('password')}
  });
  if (!j.AccessToken || !j.User?.Id) throw Error('Jellyfin 로그인 응답을 확인해 주세요');
  return j;
}
function jfEntries(items) {
  return items.filter(f => f.Id && (f.IsFolder || ['Video','Audio'].includes(f.MediaType))).map(f => {
    const container = /^[a-zA-Z0-9]+$/.test(f.Container || '') ? f.Container : (f.MediaType === 'Audio' ? 'm4a' : 'mkv');
    const name = f.IsFolder || f.Name.toLowerCase().endsWith('.' + container.toLowerCase()) ? f.Name : f.Name + '.' + container;
    return {name, path:(f.IsFolder ? 'folder:' : f.MediaType === 'Audio' ? 'audio:' : 'video:') + f.Id,
      isDir:!!f.IsFolder, size:f.Size || f.MediaSources?.[0]?.Size || 0, modified:f.DateCreated};
  });
}
async function jfItems(path, query) {
  const user = await jfUser(), out = [];
  for (let start = 0; ; ) {
    const j = await OPlayer.request(jfBase() + '/Items', {headers:jfHeaders(), query:{
      UserId:user.Id, ParentId:path === 'root' ? undefined : jfId(path), StartIndex:String(start), Limit:'200',
      Fields:'MediaSources,DateCreated', SortBy:'SortName', SortOrder:'Ascending', ...query
    }});
    if (!Array.isArray(j.Items)) throw Error('Jellyfin 목록 응답이 올바르지 않습니다');
    out.push(...jfEntries(j.Items));
    start += j.Items.length;
    if (!j.Items.length || start >= j.TotalRecordCount || j.Items.length < 200 && j.TotalRecordCount == null) return out;
    if (start >= 20000) throw Error('목록이 너무 큽니다. 하위 폴더에서 검색해 주세요');
  }
}
globalThis.plugin = {
  validateSettings() {
    if (!/^https:\/\/[^/?#]+(?:\/[^?#]*)?$/.test(OPlayer.config.endpoint || '')) return 'HTTPS 서버 기본 주소를 입력하세요';
    return OPlayer.config.username?.trim() ? null : '사용자 이름을 입력하세요';
  },
  async authenticate() { return {sessionToken:(await jfLogin()).AccessToken}; },
  async refresh() { return plugin.authenticate(); },
  async accountName() { const user = await jfUser(); return 'Jellyfin · ' + user.Name; },
  async list({path}) {
    if (path !== 'root') return jfItems(path, {Recursive:'false'});
    const user = await jfUser();
    const j = await OPlayer.request(jfBase() + '/Users/' + encodeURIComponent(user.Id) + '/Views', {headers:jfHeaders()});
    if (!Array.isArray(j.Items)) throw Error('Jellyfin 라이브러리 응답이 올바르지 않습니다');
    return jfEntries(j.Items);
  },
  async search({path, query}) {
    if (!query.trim()) return [];
    return jfItems(path, {Recursive:'true', SearchTerm:query.trim(), IncludeItemTypes:'Movie,Episode,Video,Audio'});
  },
  async stream({path}) {
    if (!/^(video|audio):/.test(path)) throw Error('영상 또는 음악 파일을 선택해 주세요');
    // API 4 cannot export a secret reference in a stream URL/header. Obtain a
    // fresh server token here; never read the stored password or session in JS.
    const login = await jfLogin(), id = jfId(path);
    const j = await OPlayer.request(jfBase() + '/Users/' + encodeURIComponent(login.User.Id) + '/Items/' + id,
      {headers:{'X-Emby-Token':login.AccessToken}});
    const source = j.MediaSources?.[0];
    if (source?.IsInfiniteStream || j.Type === 'LiveTvChannel') throw Error('Live TV는 지원하지 않습니다');
    const route = path.startsWith('audio:') ? 'Audio' : 'Videos';
    const url = jfBase() + '/' + route + '/' + id + '/stream?Static=true&api_key=' + encodeURIComponent(login.AccessToken)
      + (source?.Id ? '&MediaSourceId=' + encodeURIComponent(source.Id) : '');
    return {url, size:source?.Size || 0, name:j.Name};
  }
};
