// @oplayer {"hosts":["open-api.mybox.naver.com","*.naver.com","*.naver.net"],"authHosts":["open-api.mybox.naver.com"],"auth":{"type":"bearer","help":"MYBOX PC 웹 → 설정 → 계정 및 개인 액세스 토큰 관리에서 토큰을 생성해 입력하세요. 토큰이 만료되면 새 토큰으로 다시 연결해야 합니다. 공식 API는 암호 폴더·공유받은 폴더를 지원하지 않습니다.","consoleUrl":"https://developers.mybox.naver.com/getting-started"},"settings":[{"key":"displayName","label":"연결 이름 (선택)","type":"text"},{"key":"accessToken","label":"개인 액세스 토큰 (PAT)","type":"password","required":true}],"setup":{"help":"MYBOX 설정에서 파일 조회·다운로드·업로드·폴더 생성 가능한 개인 액세스 토큰을 발급하세요. 내 파일의 OPlayer Sync 폴더에 JSON만 저장합니다. 토큰 만료 후 같은 계정의 새 토큰으로 연결하세요.","consoleUrl":"https://developers.mybox.naver.com/getting-started"},"api":5,"id":"sync.mybox","name":"네이버 MYBOX 동기화","version":"1.0.0","kind":"resource","capabilities":["sync"],"requiresHost":["syncStorage"],"platforms":["android","windows","linux","macos"]}
const api='https://open-api.mybox.naver.com/v1/drive/';
globalThis.plugin={
  async _resources(path){
    const out=[],seen=new Set();let cursor='';
    do{const j=await OPlayer.request(api+path+'?count=1000'+(cursor?'&cursor='+encodeURIComponent(cursor):''));out.push(...j.resources);cursor=j.responseMetaData?.nextCursor||'';
      if(cursor&&seen.has(cursor))throw Error('MYBOX 목록 페이지가 반복됩니다');seen.add(cursor);
    }while(cursor);return out;
  },
  async _folder(){
    const found=(await plugin._resources('resources')).find(f=>f.type==='folder'&&f.name==='OPlayer Sync');if(found)return found.resourceId;
    const r=await OPlayer.request(api+'folders',{method:'POST',body:{folderName:'OPlayer Sync'},response:'raw'});
    if(r.status>=200&&r.status<300)return JSON.parse(r.body).resourceId;
    if(r.status===409){const existing=(await plugin._resources('resources')).find(f=>f.type==='folder'&&f.name==='OPlayer Sync');if(existing)return existing.resourceId;}
    throw Error('MYBOX 동기화 폴더를 준비하지 못했습니다 (HTTP '+r.status+')');
  },
  async accountName(){await plugin._folder();return OPlayer.config.displayName||'네이버 MYBOX';},
  async syncAccount(){return {id:await plugin._folder(),name:OPlayer.config.displayName||'네이버 MYBOX'};},
  async syncList(){const folder=await plugin._folder();const rows=await plugin._resources('folders/'+encodeURIComponent(folder)+'/resources');return rows.filter(f=>f.type==='file'&&/^oplayer-sync-v1-.+\.json$/.test(f.name)).map(f=>({id:f.resourceId,name:f.name}));},
  async syncRead({id}){const j=await OPlayer.request(api+'files/'+encodeURIComponent(id)+'/download');if(!j.downloadUrl)throw Error('MYBOX 다운로드 주소가 없습니다');return OPlayer.request(j.downloadUrl,{authenticated:false});},
  async syncWrite({name,document}){
    const parentId=await plugin._folder(),content=JSON.stringify(document);
    const fileSize=encodeURIComponent(content).replace(/%[0-9A-F]{2}|./g,'x').length;
    const j=await OPlayer.request(api+'files',{method:'POST',body:{fileName:name,fileSize,parentId,isOverwrite:true}});
    if(!j.uploadUrl)throw Error('MYBOX 업로드 주소가 없습니다');let boundary;
    do{boundary='oplayer-'+Date.now()+'-'+Math.random().toString(36).slice(2);}while(content.includes(boundary));
    const result=await OPlayer.request(j.uploadUrl,{method:'POST',authenticated:false,headers:{'Content-Type':'multipart/form-data; boundary='+boundary},body:'--'+boundary+'\r\nContent-Disposition: form-data; name="Filedata"; filename="'+name+'"\r\nContent-Type: application/json\r\n\r\n'+content+'\r\n--'+boundary+'--\r\n'});
    if(!result.resourceId)throw Error('MYBOX 저장 결과를 확인하지 못했습니다');return true;
  }
};
