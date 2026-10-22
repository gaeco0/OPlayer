// @oplayer {"api":4,"id":"cloud.s3","name":"S3 호환 스토리지","version":"1.1.1","kind":"resource","hosts":[],"root":"","rootTitle":"S3 버킷","auth":{"type":"s3","help":"AWS S3·Cloudflare R2·MinIO 등 S3 호환 서버의 HTTPS Endpoint, 버킷, 리전, Access Key를 입력하세요. 버킷 목록 조회와 객체 읽기 권한이 필요합니다. R2 리전은 auto, MinIO 기본 리전은 us-east-1입니다. 네이버 클라우드 Object Storage는 ListObjects V1을 켜 주세요. MYBOX와는 별도 서비스입니다.","consoleUrl":"https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-iam.html"},"setup":{"help":"AWS S3·Cloudflare R2·MinIO 등 S3 호환 서버의 HTTPS Endpoint, 버킷, 리전, Access Key를 입력하세요. 버킷 목록 조회와 객체 읽기 권한이 필요합니다. R2 리전은 auto, MinIO 기본 리전은 us-east-1입니다. 네이버 클라우드 Object Storage는 ListObjects V1을 켜 주세요. MYBOX와는 별도 서비스입니다.","consoleUrl":"https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-iam.html"},"settings":[{"key":"displayName","label":"연결 이름 (선택)","type":"text"},{"key":"endpoint","label":"S3 Endpoint URL","type":"url","required":true},{"key":"bucket","label":"버킷 이름","type":"text","required":true},{"key":"region","label":"리전","type":"text","required":true,"default":"us-east-1"},{"key":"accessKeyId","label":"Access Key ID","type":"text","required":true},{"key":"secretAccessKey","label":"Secret Access Key","type":"password","required":true},{"key":"sessionToken","label":"Session Token (임시 자격 증명 사용 시)","type":"password"},{"key":"virtualHosted","label":"버킷을 호스트명 앞에 붙이기","type":"boolean","default":false,"description":"가상 호스트 방식. 끄면 /버킷/ 경로 방식을 사용합니다."},{"key":"listV1","label":"ListObjects V1 사용","type":"boolean","default":false,"description":"네이버 클라우드 Object Storage 등 V2 미지원 서버용"}],"capabilities":["storage"]}
const s3Children = (node, name) => (node.children || []).filter(n => n.name === name);
const s3Text = (node, name) => s3Children(node, name)[0]?.text || '';
const s3Url = path => OPlayer.config.bucketUrl + path.split('/').map(encodeURIComponent).join('/');
globalThis.plugin = {
  async accountName() {
    const j = await OPlayer.request(OPlayer.config.bucketUrl + '?delimiter=%2F&max-keys=1' + (OPlayer.config.listV1 ? '' : '&list-type=2'), {response:'xml'});
    if (j.name !== 'ListBucketResult') throw new Error('S3 버킷 응답을 확인해 주세요');
    return OPlayer.config.bucket;
  },
  async list({path}) {
    const prefix = path || '', out = [], folders = new Set(), seen = new Set();
    let cursor = '';
    do {
      const query = {delimiter:'/', prefix, 'max-keys':'1000', 'encoding-type':'url'};
      if (!OPlayer.config.listV1) query['list-type'] = '2';
      if (cursor) query[OPlayer.config.listV1 ? 'marker' : 'continuation-token'] = cursor;
      const url = OPlayer.config.bucketUrl + '?' + Object.entries(query).map(([k,v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&');
      const j = await OPlayer.request(url, {response:'xml'});
      if (j.name !== 'ListBucketResult') throw new Error('S3 목록 응답이 올바르지 않습니다');
      const decode = s3Text(j, 'EncodingType') === 'url' ? decodeURIComponent : v => v;
      for (const f of s3Children(j, 'CommonPrefixes')) {
        const key = decode(s3Text(f, 'Prefix'));
        if (!key.startsWith(prefix) || key === prefix || folders.has(key)) continue;
        folders.add(key);
        out.push({name:key.slice(prefix.length).replace(/\/$/, ''), path:key, isDir:true});
      }
      let lastKey = '';
      for (const f of s3Children(j, 'Contents')) {
        const key = decode(s3Text(f, 'Key')); lastKey = key;
        if (!key.startsWith(prefix) || key === prefix || key.endsWith('/')) continue;
        out.push({name:key.slice(prefix.length), path:key, isDir:false, size:Number(s3Text(f, 'Size')), modified:s3Text(f, 'LastModified')});
      }
      if (s3Text(j, 'IsTruncated') !== 'true') break;
      cursor = OPlayer.config.listV1 ? decode(s3Text(j, 'NextMarker')) || lastKey : s3Text(j, 'NextContinuationToken');
      if (!cursor || seen.has(cursor)) throw new Error('S3 다음 페이지 정보를 읽을 수 없습니다');
      seen.add(cursor);
    } while (true);
    return out;
  },
  async stream({path, refresh}) {
    const url = s3Url(path);
    const headers = refresh ? {} : await OPlayer.request(url, {method:'HEAD', response:'headers'});
    return {url:await OPlayer.request(url, {response:'signedUrl'}), size:refresh ? 0 : Number(headers['content-length']), name:path.split('/').pop(), refreshEachRequest:true};
  }
};
