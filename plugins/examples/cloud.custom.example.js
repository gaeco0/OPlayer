// @oplayer {"api":2,"id":"cloud.custom.example","name":"사용자 정의 저장소 예제","version":"1.0.0","kind":"cloud","hosts":[],"authHosts":[],"networkSettings":["endpoint"],"authSettings":["endpoint"],"root":"root","auth":{"type":"script"},"setup":{"help":"공통 SDK만으로 설정·폼 로그인·세션 갱신·HMAC 요청을 구현하는 가상 서비스 예제입니다. 실제 클라우드 서비스가 아닙니다."},"settings":[{"key":"endpoint","label":"서버 주소","type":"url","default":"https://api.example.com","required":true},{"key":"account","label":"사용자 이름","type":"text","required":true},{"key":"password","label":"비밀번호","type":"password","required":true},{"key":"collection","label":"목록 종류","type":"select","options":["media","all"],"default":"media"},{"key":"includeHidden","label":"숨김 항목 포함","type":"boolean","default":false}]}
globalThis.plugin = {
  validateSettings() { return OPlayer.config.account?.trim() ? null : '사용자 이름을 입력해 주세요'; },
  async authenticate() {
    const j = await OPlayer.request(OPlayer.config.endpoint + '/session', {
      method:'POST', bodyFields:{account:OPlayer.config.account,password:OPlayer.secret('password')}
    });
    return {sessionKey:j.sessionKey};
  },
  async refresh() { return plugin.authenticate(); },
  async accountName() {
    const j = await OPlayer.request(OPlayer.config.endpoint + '/profile', {
      headers:{'X-Session':OPlayer.secret('sessionKey')}
    });
    return j.name;
  },
  async list() {
    const proof = await OPlayer.crypto.hmac('sha256',OPlayer.secret('sessionKey'),'list:' + OPlayer.config.collection);
    const j = await OPlayer.request(OPlayer.config.endpoint + '/files', {
      query:{collection:OPlayer.config.collection,hidden:String(OPlayer.config.includeHidden)},
      headers:{'X-Session':OPlayer.secret('sessionKey'),'X-Proof':proof}
    });
    return j.entries.map(f => ({name:f.name,path:f.id,isDir:f.folder,size:f.size}));
  },
  async stream({path}) {
    return OPlayer.request(OPlayer.config.endpoint + '/files/' + encodeURIComponent(path) + '/stream', {
      headers:{'X-Session':OPlayer.secret('sessionKey')}
    });
  }
};
