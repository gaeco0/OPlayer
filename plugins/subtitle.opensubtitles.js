// @oplayer {"api":4,"id":"subtitle.opensubtitles","name":"OpenSubtitles","version":"1.0.0","kind":"subtitle","hosts":["api.opensubtitles.com","vip-api.opensubtitles.com","dl.opensubtitles.com"],"authHosts":["api.opensubtitles.com","vip-api.opensubtitles.com"],"settings":[{"key":"apiKey","type":"password","label":"API Key","required":true},{"key":"username","type":"text","label":"OpenSubtitles.com 사용자 이름","required":true},{"key":"password","type":"password","label":"비밀번호","required":true},{"key":"userAgent","type":"text","label":"User-Agent","default":"OPlayer v0.1.4","required":true},{"key":"language","type":"text","label":"기본 자막 언어 코드","default":"ko","required":true,"description":"예: ko, en, ja"},{"key":"autoApply","type":"boolean","label":"재생 시작 시 자동 검색·적용","default":false,"description":"사용할 자막이 없으면 영상 제목으로 검색해 첫 결과를 적용합니다. 검색은 영상 제목을 이 서비스에 전송합니다."}],"setup":{"help":"OpenSubtitles.com 계정과 API Consumers에서 발급한 API Key를 입력하세요. 다운로드에는 계정별 할당량이 적용됩니다. 검색은 영상 제목만 전송하며 파일 경로·브라우저 헤더는 보내지 않습니다.","consoleUrl":"https://www.opensubtitles.com/consumers"}}
globalThis.plugin = {
  validateSettings() {
    return /^[a-z]{2,3}(?:-[a-z]{2,4})?$/.test(OPlayer.config.language || 'ko')
      ? null : '언어 코드(예: ko, en, ja)를 입력해 주세요';
  },
  async api(path, {body, token, base = 'api.opensubtitles.com'} = {}) {
    if (!['api.opensubtitles.com', 'vip-api.opensubtitles.com'].includes(base)) throw Error('잘못된 API 서버');
    const headers = {'Api-Key':OPlayer.secret('apiKey'), 'User-Agent':OPlayer.config.userAgent || 'OPlayer v0.1.4', Accept:'application/json'};
    if (token) headers.Authorization = 'Bearer ' + token;
    const response = await OPlayer.request('https://' + base + '/api/v1/' + path, {
      method:body ? 'POST' : 'GET', headers, ...(body ? {body} : {}), response:'raw'
    });
    if (response.status === 401) throw Error('API Key·사용자 이름·비밀번호를 확인해 주세요');
    if (response.status === 403 || response.status === 406) throw Error('OpenSubtitles 권한 또는 다운로드 할당량을 확인해 주세요');
    if (response.status === 429) throw Error('요청이 너무 많습니다. 잠시 뒤 다시 시도해 주세요');
    if (response.status < 200 || response.status >= 300) throw Error('OpenSubtitles 요청 실패 (HTTP ' + response.status + ')');
    return JSON.parse(response.body);
  },
  async searchSubtitles({query, language, page = 1}) {
    const result = await plugin.api('subtitles?languages=' + encodeURIComponent(language || 'ko') +
      '&order_by=download_count&order_direction=desc&page=' + page + '&query=' + encodeURIComponent(query));
    const items = [];
    for (const entry of result.data || []) {
      const a = entry.attributes || {};
      for (const file of a.files || []) {
        items.push({id:String(file.file_id), title:file.file_name || a.release || query,
          language:a.language || language, release:a.release || '', downloads:a.download_count || 0,
          data:{fileId:file.file_id}});
      }
    }
    return {items:items.slice(0,100), page:result.page || page, totalPages:result.total_pages || 1};
  },
  async downloadSubtitle({item}) {
    const fileId = Number(item.data?.fileId);
    if (!Number.isSafeInteger(fileId) || fileId <= 0) throw Error('자막 파일 ID가 잘못됐습니다');
    const session = await plugin.api('login', {body:{username:OPlayer.config.username, password:OPlayer.secret('password')}});
    if (!session.token) throw Error('OpenSubtitles 로그인에 실패했습니다');
    const base = String(session.base_url || 'api.opensubtitles.com').replace(/^https:\/\//, '').replace(/\/$/, '');
    const download = await plugin.api('download', {base, token:session.token, body:{file_id:fileId, sub_format:'srt'}});
    if (typeof download.link !== 'string') throw Error('자막 다운로드 주소가 없습니다');
    return {url:download.link, format:'srt', title:download.file_name || item.title};
  }
};
