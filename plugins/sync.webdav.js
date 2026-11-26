// @oplayer {"api":5,"id":"sync.webdav","name":"WebDAV 동기화","version":"1.0.0","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage","webdavSync"],"platforms":["android","windows","linux","macos"],"hosts":[],"networkSettings":["endpoint"],"authSettings":["endpoint"],"auth":{"type":"script"},"settings":[{"key":"endpoint","label":"동기화 폴더 HTTPS URL","type":"url","required":true},{"key":"username","label":"사용자 이름","type":"text","required":true},{"key":"password","label":"비밀번호 / 앱 비밀번호","type":"password","required":true}],"setup":{"help":"NAS·Nextcloud·ownCloud 등 WebDAV 서버에 전용 폴더를 먼저 만들고 HTTPS URL과 계정을 입력하세요. 폴더 목록 조회·파일 읽기·쓰기 권한이 필요합니다. 모든 기기에 같은 폴더 URL을 지정하세요. Basic 인증(앱 비밀번호)을 지원합니다."}}
const children=(node,name)=>(node.children||[]).filter(n=>n.name===name);
const text=(node,name)=>children(node,name)[0]?.text||'';
const syncName=name=>/^oplayer-sync-v1-[A-Za-z0-9_-]+\.json$/.test(name);
globalThis.plugin={
  _base(){return OPlayer.config.endpoint.replace(/\/+$/,'').replace(/^(https?:\/\/[^/]+)(.*)$/,
    (_,origin,path)=>origin.toLowerCase()+path.split('/').map(s=>encodeURIComponent(decodeURIComponent(s))).join('/'))+'/';},
  _url(name){if(!syncName(name))throw Error('잘못된 동기화 파일 이름');return plugin._base()+encodeURIComponent(name);},
  _request(url,options={}){return OPlayer.request(url,{...options,basicAuth:{username:OPlayer.secret('username'),password:OPlayer.secret('password')}});},
  validateSettings(){if((OPlayer.config.username||'').includes(':'))throw Error('사용자 이름에는 콜론을 사용할 수 없습니다');return true;},
  async accountName(){await plugin.syncList();return OPlayer.config.username+' · '+plugin._base();},
  async syncAccount(){return {id:plugin._base(),name:await plugin.accountName()};},
  async syncList(){
    const root=await plugin._request(plugin._base(),{method:'PROPFIND',headers:{Depth:'1','Content-Type':'application/xml; charset=utf-8'},body:'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',response:'xml'});
    if(root.name!=='multistatus')throw Error('WebDAV 폴더 목록 응답이 올바르지 않습니다');
    const files=[],base=plugin._base(),path=base.replace(/^https?:\/\/[^/]+/,'');
    for(const item of children(root,'response')){
      const href=text(item,'href');let name;
      if(href.startsWith(base))name=href.slice(base.length);
      else if(href.startsWith(path))name=href.slice(path.length);
      else if(!href.includes('/'))name=href;
      else continue;
      try{name=decodeURIComponent(name);}catch(_){continue;}
      if(!syncName(name))continue;
      const props=children(item,'propstat').filter(p=>/^HTTP\/\S+ 200(?: |$)/.test(text(p,'status'))).flatMap(p=>children(p,'prop'));
      if(!props.length||props.some(p=>children(p,'resourcetype').some(t=>children(t,'collection').length)))continue;
      if(!files.some(f=>f.id===name))files.push({id:name,name});
      if(files.length>512)throw Error('동기화 파일이 너무 많습니다');
    }
    return files;
  },
  syncRead({id}){return plugin._request(plugin._url(id));},
  async syncWrite({name,document}){await plugin._request(plugin._url(name),{method:'PUT',body:document,response:'headers'});return true;}
};
