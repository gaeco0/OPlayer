# OPlayer 확장앱

설정 → **확장앱**에서 저장소를 추가하고 목록을 확인한 뒤 설치합니다.
확장앱은 `.js` 파일이며 APK·앱 재설치 없이 로드합니다. JS 파일 직접 가져오기도 지원합니다.
현재 SDK는 JavaScript API 1·2이며 Dart 소스·Flutter 위젯·네이티브 코드를 동적으로 로드하지 않습니다.

공식 저장소 JSON:
https://raw.githubusercontent.com/gaeco0/OPlayer/main/plugins/repository.json

Google Drive·Dropbox·OneDrive는 공식 확장앱으로 제공됩니다. 기존 계정·토큰·리소스 키는 유지됩니다.
기존 동작을 유지하도록 첫 시작에 기본 클라우드 확장앱을 포함하며 삭제 후 저장소에서 다시 설치할 수 있습니다.
확장앱의 앱 등록 정보는 **설정 → 확장앱 → 해당 확장앱의 설정(톱니바퀴)** 안에서 관리합니다.
끄거나 삭제해도 등록 정보와 계정은 보관되며, 삭제된 확장앱의 설정 항목은 표시하지 않습니다.

S3 호환 스토리지·Box·네이버 MYBOX도 공식 저장소에서 선택 설치할 수 있습니다.
이 문서의 공통 SDK를 포함한 앱으로 한 번 업데이트하면, 이후 같은 SDK를 사용하는 공급자는 JS 파일·저장소 목록만
추가하면 됩니다. 공급자별 설정·서버 주소·인증 흐름을 추가할 때 앱을 다시 빌드하지 않습니다.
새 OS 네이티브 기능처럼 SDK 자체에 없는 기능을 추가할 때만 호스트 앱 변경이 필요합니다.
기존 API 1 확장앱도 계속 사용할 수 있습니다. 저장소 목록의 형식은 그대로 `api: 1`입니다.

| 확장앱 | 해당 확장앱 설정에서 입력할 정보 | 지원 범위 |
| --- | --- | --- |
| S3 호환 스토리지 | Endpoint·버킷·리전·Access Key ID·Secret Access Key, 선택적 Session Token | AWS S3·R2·MinIO 등, 경로/가상 호스트 방식, ListObjects V1/V2, 목록 조회·재생 |
| Box | 사용자 OAuth 앱의 Client ID·Client Secret, 표시된 복귀 주소 등록 | 로그인·토큰 자동 갱신·폴더 탐색·재생 |
| 네이버 MYBOX | MYBOX 웹에서 생성한 개인 액세스 토큰(PAT) | 일반 폴더 탐색·재생, 암호 폴더·공유받은 폴더는 API 미지원 |

S3 Endpoint는 HTTPS를 사용합니다(로컬 개발용 localhost·127.0.0.1 HTTP 허용). 리전은 서버가 요구하는 값으로
지정하세요. 예: AWS `ap-northeast-2`, R2 `auto`, MinIO 기본값 `us-east-1`.
네이버 클라우드 Object Storage는 **MYBOX와 다른 서비스**이며 S3 확장앱에서 `ListObjects V1`을 켭니다.
버킷 목록 읽기 및 객체 읽기 권한이 필요하며, 업로드·삭제는 지원하지 않습니다.
접속 정보를 바꿔 다시 연결하면 별도 계정으로 추가됩니다. 기존 계정은 연결 당시의 인증 정보를 계속 사용합니다.

Box는 Developer Console에서 OAuth 2.0 앱과 파일·폴더 읽기 권한을 설정한 뒤 확장앱에 표시되는
`http://localhost:53682/callback` 복귀 주소를 등록합니다. 모바일도 같은 localhost 방식을 사용하며 로그인 후
앱으로 돌아오면 연결을 이어갑니다. 조직 정책에 따라 관리자의 앱 승인이 필요할 수 있습니다.
Client Secret은 Client ID에 연결해 보안 저장소에 보관하므로 새 앱 등록으로 바꿔도 기존 연결의 등록 정보를 덮어쓰지 않습니다.

MYBOX는 PC 웹 설정 → 계정 및 개인 액세스 토큰 관리에서 토큰을 생성합니다. 토큰 만료·폐기 시 새 토큰으로
재연결해야 합니다. 다운로드 URL이 1회용이므로 앱의 로컬 Range 프록시가 탐색 요청마다 새 URL을 발급받습니다.
S3와 Box도 재생 중 탐색 시 새 임시 URL을 얻습니다. 서비스별 권한·요금제·API 호출 제한은 해당 서비스 정책을 따릅니다.

공식 API 문서: [AWS SigV4](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html),
[Box OAuth](https://developer.box.com/reference/post-oauth2-token),
[Box 다운로드](https://developer.box.com/guides/downloads/get-url),
[MYBOX 시작하기](https://developers.mybox.naver.com/getting-started),
[MYBOX 다운로드](https://developers.mybox.naver.com/docs/files_download).

## 저장소 JSON

실제 목록은 [repository.json](repository.json)을 참고하세요.

```json
{
  "api": 1,
  "name": "확장앱 저장소 이름",
  "description": "저장소 소개",
  "plugins": [
    {
      "id": "site.example",
      "name": "사이트 확장 예제",
      "kind": "site",
      "description": "사이트 동영상 감지와 광고 차단",
      "features": ["동영상 감지", "다운로드 보완", "광고 차단"],
      "author": "개발자 이름",
      "version": "1.0.0",
      "downloadUrl": "https://example.com/site.example.js",
      "sha256": "여기에 JS 파일의 실제 SHA-256 64자리",
      "homepage": "https://example.com/"
    }
  ]
}
```

`id`, `name`, `version`, `downloadUrl`, `sha256`는 필수입니다. `url`은 `downloadUrl`의 이전 별칭으로도 받습니다.
상대 다운로드 URL은 저장소 JSON 주소 기준으로 해석합니다. 외부 저장소와 다운로드는 HTTPS를 사용합니다
(개발용 localhost·127.0.0.1 HTTP 허용). 리디렉션은 따라가지 않으므로 최종 파일 URL을 넣습니다.
JSON 추가는 코드 설치·실행을 하지 않으며, 사용자가 항목을 선택하고 권한을 확인한 뒤 설치합니다.
같은 ID는 교체하고 버전이 달라지면 교체 버튼을 제공합니다. SHA-256은 무결성 검사이며 개발자 서명은 아닙니다.

공식 클라우드 스크립트를 수정하면 버전도 올리고 다음을 실행해 목록·해시를 갱신합니다.

```sh
python tools/update_plugin_repository.py
```

## JS 파일 규약

첫 줄은 `// @oplayer `와 JSON 메타데이터이며 나머지는 `globalThis.plugin = {...}`입니다.
`id`, `name`, `version`, `api: 1 | 2`, `kind: "site" | "cloud"`를 지정합니다.
도메인은 정확한 호스트 또는 `*.example.com` 형식입니다. 와일드카드는 하위 호스트만 포함합니다.

### 사이트 기능

[examples/site.example.js](examples/site.example.js)는 실제로 로드 가능한 예제입니다.

- `sites`: 스크립트를 실행하고 미디어를 보완할 페이지 도메인.
- `hosts`: 앱에서 `OPlayer.request`로 호출할 수 있는 HTTPS 도메인.
- `blockRules: [{"urlFilter": "정규식"}]`: 해당 사이트의 네트워크 요청 차단 규칙.
- `page(api)`: WebView에서 실행. DOM을 읽고 `api.reportMedia(url, hint)`로 미디어를 보고합니다.
  `api.config`와 `OPlayer.config`로 비밀값을 제외한 확장앱 설정을 읽습니다.
  `hint`는 MIME 또는 `hls` 등의 감지 힌트입니다. 페이지 DOM API로 광고 요소를 숨길 수도 있습니다.
- `resolveDownload({url, pageUrl, referer, title, kind, headers})`: 앱의 제한된 JS 엔진에서 실행.
  `null`을 반환하면 기존 동작을 유지합니다. `{url, headers, kind, title}`의 필요한 필드만 반환합니다.
  기존 헤더와 반환 헤더를 합칩니다. 이 함수는 다운로드와 재생에 공통 적용됩니다.
- `OPlayer.request(url, {method: "GET" | "POST", headers, body, response: "json" | "text"})`:
  `hosts` 범위에만 요청합니다. 기본 응답은 JSON, 리디렉션 미지원, 응답 최대 8MB입니다.

Android는 WebView 요청 콜백, Windows는 DevTools 요청 차단, Apple WebView는 콘텐츠 차단 규칙을 사용합니다.
설치·교체·끄기 후 페이지를 새로고침하면 기존 페이지 스크립트가 정리되고 새 구성이 적용됩니다.
광고 URL 규칙은 플랫폼마다 지원하는 정규식 문법이 다를 수 있어 단순한 패턴을 권장합니다.

### 클라우드 기능

공식 `cloud.*.js`를 참고하세요. 계정 연결 UI에는 설치·활성화된 클라우드 확장앱이 표시됩니다.
`oauth`를 선언한 클라우드 확장앱에는 자체 설정 화면을 제공합니다. 추가 공급자의 Client ID도 그 화면에
확장앱 ID별로 저장하며 로그인 시 사용합니다. 등록 정보가 없으면 연결 과정에서 해당 확장앱 설정을 엽니다.

- `oauth`: `authEndpoint`, `tokenEndpoint`, `scopes`, 선택적 `clientId`, `extraAuthParams`,
  `loopbackHost`, `mobileRedirectUri`를 지정합니다. 로그인·PKCE·갱신·보안 저장은 앱이 담당합니다.
- `hosts`와 `authHosts`: API 요청·Bearer 인증 전송을 허용하는 도메인. `authHosts`는 `hosts`에도 포함합니다.
- `root`, `rootTitle`: 초기 폴더 ID와 제목.
- `accountName({})`: 계정 이름 문자열.
- `list({path})`: `[{name,path,isDir,size,modified,thumbnailUrl}]`.
- `stream({path})`: `{url, authenticated?: true}`. 인증을 요청하면 URL이 `authHosts`에 속해야 합니다.
- `OPlayer.request(url, {method, body})`: 앱이 Bearer 인증을 붙이고 401 시 한 번 갱신합니다.
  플러그인에 토큰 문자열을 전달하지 않으며, 인증 리디렉션은 따라가지 않습니다.
- Android Google 계정 선택·인증은 기존 네이티브 브리지를 재사용합니다.

### 공통 설정·인증 SDK

설정 항목을 Dart에 등록하지 않습니다. 확장앱 첫 줄의 `settings` 배열이 자체 설정 화면을 정의합니다.
공식 여섯 확장앱도 같은 화면 생성기를 사용하며, 구형 공식 확장앱은 앱에 포함된 설정 선언만 보완합니다.
저장된 구형 JS 실행 코드·네트워크 권한을 자동으로 교체하지 않습니다.

```json
{
  "settings": [
    {"key":"endpoint","label":"서버 주소","type":"url","required":true},
    {"key":"account","label":"사용자 이름","type":"text","required":true},
    {"key":"password","label":"비밀번호","type":"password","required":true},
    {"key":"collection","label":"목록 종류","type":"select","options":["media","all"],"default":"media"},
    {"key":"includeHidden","label":"숨김 항목 포함","type":"boolean","default":false}
  ],
  "networkSettings":["endpoint"],
  "authSettings":["endpoint"],
  "auth":{"type":"script"},
  "setup":{"help":"이 확장앱의 설정 안내","consoleUrl":"https://example.com/help"}
}
```

- 설정은 최대 100개이며 `text`, `password`, `boolean`, `select`, `url`을 지원합니다. 선택적 `description`,
  `default`, `required`, `platforms`를 선언합니다. 비밀번호 기본값은 허용하지 않습니다.
- `setup`의 안내·등록 링크·`redirectUris` 목록도 확장앱이 제공합니다. `validateSettings()`는 공개 설정만
  검사하고 오류 문자열 또는 `null`을 반환합니다. 검증 중에는 네트워크 요청을 보내지 않습니다.
- 값은 확장앱별로 보관합니다. `password`는 보안 저장소에만 저장하며 JS 설정·WebView·일반 환경설정에 노출하지 않습니다.
  `OPlayer.config`에는 선언된 비밀값 이외의 설정만 전달합니다. 사이트 확장앱도 동일한 설정을 사용할 수 있습니다.
- `networkSettings`는 사용자가 지정한 URL 설정에 요청을 허용합니다. URL의 origin과 기본 경로가 범위이며
  HTTPS를 사용합니다(개발용 localhost HTTP 허용). `authSettings`는 그중 비밀값 전송을 허용할 설정입니다.
  고정 호스트는 기존 `hosts`·`authHosts`로 선언합니다.
- `OPlayer.secret('password', {prefix:'', suffix:''})`는 비밀 문자열을 읽는 함수가 아니라 불투명 참조를 만듭니다.
  허용된 인증 서버로 보내는 `headers`, `query`, `body`, `bodyFields` 안에서만 네이티브가 값을 치환합니다.
- 앱 측 JS에서 `OPlayer.crypto.hash(algorithm,data)`, `OPlayer.crypto.hmac(algorithm,key,data,keyEncoding='utf8')`를
  `await`합니다. 알고리즘은 `sha256`, `sha512`, `sha1`, `md5`, 결과는 hex입니다. HMAC 키에는 비밀값 참조를
  사용할 수 있고, 앞 단계 HMAC 결과는 `keyEncoding='hex'`로 연결합니다. 입력은 1Mi 글자, 키는 64Ki 글자,
  호출 전체는 기존 최대 200회·60초 제한을 따릅니다. 이 API는 WebView 페이지 훅에는 노출하지 않습니다.
- HTTP는 `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, 문자열/JSON `body`, 폼 `bodyFields`, `headers`, `query`를
  지원합니다. 클라우드와 사이트 확장앱이 같은 요청 생성·응답 해석 코드를 사용하며 리디렉션을 자동으로 따라가지 않습니다.
  `response`는 `json`(기본), `text`, `xml`, `headers`, `redirect`, `raw`입니다. `raw`는 오류 상태도
  `{status,headers,body}`로 반환해 스크립트가 직접 판단하게 합니다.
- 새 인증 프로토콜은 `auth.type='script'`로 작성합니다. 선택적 `authenticate()`가 연결 시 실행되고
  반환한 세션 상태는 계정별 보안 저장소에 보관합니다. 설정·계정 식별자를 덮어쓰는 응답은 거부합니다.
  일반 요청이 401로 실패하면 `refresh()`의 새 상태를 저장한 뒤 해당 JS 작업 전체를 한 번 다시 실행합니다.
  세션 키도 `OPlayer.secret('sessionKey')`로 참조합니다. `raw` 응답의 상태 처리는 스크립트가 담당합니다.

[cloud.custom.example.js](examples/cloud.custom.example.js)는 앱에 공급자 코드를 추가하지 않고 설정·폼 로그인·
HMAC 인증·세션 갱신·목록·재생 주소를 구현하는 가상 서비스 예제입니다. 실제 서비스는 아닙니다.
`test/plugin_sdk_test.dart`는 이 파일을 앱에 없는 새 ID로 설치해 위 흐름을 검증합니다.

공통 OAuth·Bearer·SigV4 및 응답 기능:

- `auth: {"type":"s3" | "bearer" | "script"}`로 공통 인증 방식을 선택하고 `settings`로 입력 항목을 선언합니다.
  OAuth 공급자는 기존 `oauth` 메타데이터를 사용합니다. Bearer는 `accessToken`, SigV4는 공식 S3 확장앱의 표준
  설정 키를 사용합니다. 다른 인증 방식은 `script`와 공통 HTTP·암호 API로 작성합니다.
- `oauth.requiresClientSecret: true`는 보안 저장소의 Secret을 네이티브 토큰 교환·갱신에 사용합니다.
  `oauth.pkce: false`는 PKCE 미지원 공급자용입니다. 기본값은 PKCE 사용입니다. OAuth state 검사는 항상 유지합니다.
  `oauth.loopbackOnMobile: true`는 Box처럼 커스텀 스킴 복귀를 허용하지 않는 공급자용입니다.
  이 경우 모바일에서도 임시 localhost 서버를 열고 시스템 브라우저에서 로그인합니다.
- S3 스크립트의 `OPlayer.config`에는 `bucketUrl`, `bucket`, `listV1`만 전달합니다. 개인 토큰·Secret Access Key는
  JS에 전달하지 않습니다. 사용자 지정 Endpoint의 등록한 버킷 범위만 요청·서명하며 GET·HEAD만 지원합니다.
- `OPlayer.request(url, {response:"xml"})`는 XML을 `{name, children, text?}` 트리로 반환합니다.
  `{method:"HEAD",response:"headers"}`는 응답 헤더만 반환합니다.
  S3의 `{response:"signedUrl"}`는 GET URL만 서명합니다. 키를 반환하거나 임의 호스트를 서명하지 않습니다.
- `{response:"redirect"}`는 API의 다운로드 리디렉션을 따라가지 않고 `{url}`을 반환합니다.
  API용 Bearer 헤더는 이 URL로 전송하지 않습니다.
- `stream()` 결과의 `{url,name,size,refreshEachRequest:true}`는 로컬 Range 프록시를 사용합니다.
  새 Range 연결에는 `stream({path,refresh:true})`을 다시 호출하므로 만료·1회용 URL을 재발급할 수 있습니다.
  `refresh:true` 호출은 크기 조회를 생략해도 됩니다. 플레이어 해제·계정 연결 해제 시 로컬 URL을 폐기합니다.

앱 측 실행은 호출마다 새 QuickJS 런타임을 사용합니다. 한 번의 JS 실행·Promise 루프는 200ms,
힙은 32MB, 호출 전체는 60초·최대 200개 요청으로 제한합니다. 로컬 파일·네이티브 API는 노출하지 않습니다.
WebView의 `page` 함수는 이 실행 제한 밖에서 해당 페이지의 사용자 스크립트로 실행됩니다.
페이지·요청 헤더에 접근하는 확장앱이므로 신뢰하는 개발자의 코드만 설치하세요.

## 테스트

앱을 한 번 빌드하거나 테스트용 엔진을 먼저 컴파일하세요. Windows:

```sh
cmake -S packages/quickjs_engine/native -B build/plugin-runtime -A x64
cmake --build build/plugin-runtime --config Release --parallel 4
flutter test --no-pub
```

Linux/macOS는 `cmake -S ... -B ...`에서 `-A x64`를 빼고 같은 위치에 빌드합니다.
`LIBQUICKJSC_TEST_PATH`로 DLL/공유 라이브러리 경로를 직접 지정할 수도 있습니다.
