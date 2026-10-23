# OPlayer 확장앱

설정 → **확장앱**에서 저장소를 추가하고 목록을 확인한 뒤 설치합니다.
확장앱은 `.js` 파일이며 APK·앱 재설치 없이 로드합니다. JS 파일 직접 가져오기도 지원합니다.
v0.1.3은 JavaScript API 1·2·3을 지원하며 Dart 소스·Flutter 위젯·네이티브 코드를 동적으로 로드하지 않습니다.
v0.1.5는 아래 세 유형의 공통 API 4를 지원합니다. 기존 v0.1.4 앱은 API 4가 없으므로 한 번 업데이트해야 합니다. 이후 같은 규약을 사용하는 공급자·사이트·필터는 JS와 저장소 JSON만 배포합니다.

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
기존 API 1·2·3 확장앱도 계속 사용할 수 있습니다. 새 확장앱은 유형·기능을 선언하는 `api: 4`를 사용하세요.
저장소 목록 자체의 형식은 그대로 `api: 1`이며 각 항목의 `pluginApi`가 실행 API 버전입니다.

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
      "kind": "browser",
      "pluginApi": 4,
      "capabilities": ["page", "resolveDownload", "blockRequests"],
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

공식 클라우드·자막 스크립트를 수정하면 버전도 올리고 다음을 실행해 목록·해시를 갱신합니다.

```sh
python tools/update_plugin_repository.py
```

## disable-devtool 차단

공식 저장소의 **disable-devtool 차단**(`site.disable-devtool`)을 선택 설치하고 켠 뒤 페이지를 새로고침합니다.
1.1.0부터 `sites: ["*"]` 권한으로 모든 웹사이트와 서로 다른 도메인의 iframe에 적용합니다.
설치 권한 화면에 **모든 웹사이트**로 표시됩니다. 임의 도메인에 대한 호스트 HTTP 요청 권한(`hosts`)은 추가하지 않습니다.

별도 파일로 로드되는 `disable-devtool` 요청을 차단하고, 문서 시작 시 공개 `DisableDevtool`/`disableDevtool`
API를 무효화합니다. 기본으로 콘솔의 log/debug/info/dir/dirxml/table/clear 출력을 억제해 콘솔 기반 감지 오작동을
줄입니다. warn/error는 유지하며 콘솔 억제는 해당 확장앱 설정에서 끌 수 있습니다. 확장앱을 끈 뒤 페이지를 새로고침하면 원래 상태로 돌아갑니다.

다른 코드에 합쳐지거나 이름을 숨긴 변형, 별도 타이밍·크기 감지까지 모두 차단하는 것은 보장하지 않습니다.
타이머·fetch·XHR·history·일반 페이지 이동은 변경하지 않습니다. 호스트 API 4를 지원하는 기존 앱에 JS와 목록만
배포합니다. 다만 전체 사이트 권한을 지원하지 않는 이전 앱에는 호스트 업데이트가 한 번 필요합니다.
지원 호스트에서는 이후 확장앱 업데이트만으로 반영합니다. 동작 검증은 `node test/disable_devtool_plugin_test.cjs`로 실행합니다.

## 유형별 공통 규약 (API 4)

| 유형 (`kind`) | 기능 (`capabilities`) | 필수 함수 / 선언 | 앱에서 사용하는 곳 |
|---|---|---|---|
| `player` | `subtitles` | `searchSubtitles`, `downloadSubtitle` | 플레이어 자막 메뉴·자동 검색 |
| `player` | `videoFilter` | `videoFilter` | 플레이어 화면 비율 → 영상 필터 확장앱 |
| `browser` | `page` | `page` | 허용 사이트 WebView DOM·미디어 감지 |
| `browser` | `resolveDownload` | `resolveDownload` | 브라우저 재생·다운로드 공통 경로 |
| `browser` | `blockRequests` | 비어 있지 않은 `blockRules` | 허용 사이트 광고 요청 차단 |
| `resource` | `storage` | `accountName`, `list`, `stream` | 계정 연결·파일 목록·재생 |

한 확장앱은 한 유형이며 같은 유형의 기능은 복수 선택할 수 있습니다. 미정의 유형·기능, 중복 기능,
다른 유형의 권한(`sites`, `blockRules`, `oauth`, `auth`, `canDelete`), 누락된 필수 함수는 거절합니다.
`validateSettings`는 모든 유형의 선택 훅입니다. 리소스는 `authenticate`, `refresh`와 `canDelete:true`일 때
`delete`도 사용할 수 있습니다. 내부 보조 함수는 객체 밖에 두거나 `_`로 시작하게 작성하세요.
앱이 호출할 수 있는 공개 훅은 위 규약으로 제한하며 비공개 보조 함수를 직접 호출하지 않습니다.
플레이어·리소스 코드는 WebView에 주입하지 않고 브라우저도 선언한 기능만 실행합니다.

`OPlayer.api`는 4, `OPlayer.kind`는 유형, `OPlayer.capabilities`는 선언한 기능 목록입니다.
공통 설정·비밀값 참조·HTML/XML/JSON 파서·HTTP 권한 검사는 기존 SDK를 재사용합니다.
새 네이티브 기능이나 새로운 공개 훅이 필요할 때만 호스트 API와 앱을 업데이트합니다.
JS 플러그인으로 임의 Dart 코드·Flutter 위젯·네이티브 모듈은 추가할 수 없습니다.

### 앱 배포 없이 확장앱 배포하기

1. 위 규약에서 유형과 기능을 고르고 하단 예제처럼 JS 파일을 작성합니다.
2. 설정은 JS 메타데이터의 `settings`에 선언합니다. 앱 공통 설정에 공급자 전용 코드를 추가하지 않습니다.
3. 확장앱 자체 `version`을 올리고 JS를 HTTPS로 공개합니다. 기존 ID를 유지하세요.
4. 저장소 JSON에 `kind`, `pluginApi:4`, `capabilities`, 버전·다운로드 URL·SHA-256을 반영합니다.
   이 저장소에서는 `python tools/update_plugin_repository.py`로 `plugins/*.js`를 자동 수집합니다.
5. 사용자에게 확장앱 목록 새로고침 → 설치/교체를 안내합니다. 앱 태그·APK·Actions 빌드는 필요 없습니다.
6. 브라우저는 페이지 새로고침 후, 자막/필터는 다음 검색·적용 시, 리소스는 다음 요청 시 반영됩니다.

실행 가능한 JS 예제를 포함한 검증은 `flutter test test/plugin_contract_test.dart`로 실행합니다.
CI와 동일하게 QuickJS 네이티브 테스트 라이브러리를 먼저 빌드해야 합니다(워크플로 참고).
설치 시 SHA-256·ID·버전·유형·기능 목록과 필수 훅을 확인하며, 설정·계정은 플러그인 ID로 유지합니다.

### 영상 필터 예제

[영상 색상 프리셋](player.video-presets.js)은 공식 저장소에서 선택 설치합니다(기본 강제 설치하지 않음).
확장앱 설정에서 프리셋을 정한 후 플레이어 화면 비율 메뉴에서 해당 필터를 누릅니다.

```js
// @oplayer {"api":4,"id":"player.example","name":"흑백","version":"1.0.0","kind":"player","capabilities":["videoFilter"],"hosts":[]}
globalThis.plugin = {
  videoFilter() { return {brightness:0, contrast:0, saturation:-100}; }
};
```

`videoFilter({})`는 변경할 값만 반환합니다. `brightness`, `contrast`, `saturation`은 유한한 -100~100 숫자,
`rotation`은 0/90/180/270 정수, `horizontal`, `vertical`은 boolean입니다. 빈 응답·미정의 필드·범위 초과는
적용 전 거절합니다. 네이티브 프로퍼티 문자열·파일 경로·임의 셰이더·`vf` 명령을 받지 않습니다.
필터 훅에는 HTTP/비밀값/미디어 경로를 전달하지 않으며 공개 `OPlayer.config`만 전달합니다.
적용된 값은 기존 영상 설정처럼 저장됩니다. 플러그인을 끈다고 이미 적용된 영상 값을 되돌리지는 않습니다.
원본 프리셋 또는 기존 색상·회전 설정으로 초기화할 수 있습니다. 캐스팅 수신기의 영상에는 적용되지 않습니다.

## JS 파일 규약

첫 줄은 `// @oplayer `와 JSON 메타데이터이며 나머지는 `globalThis.plugin = {...}`입니다.
`id`, `name`, `version`, `api: 4`, `kind: "player" | "browser" | "resource"`, `capabilities`를 지정합니다.
기존 `site`·`cloud`·`subtitle` 선언/API 1~3은 호환용으로 읽지만 새 확장앱에는 사용하지 마세요. ID를 유지하면 계정·설정도 유지됩니다.
도메인은 정확한 호스트 또는 `*.example.com` 형식입니다. `*.example.com`은 하위 호스트만 포함합니다.
브라우저의 `sites`에는 전체 웹사이트 권한 `*`도 허용합니다. 문서 주입·요청 차단·WebKit 콘텐츠 차단에
같은 범위를 적용하며 빈 호스트의 `about:blank`·로컬 파일은 포함하지 않습니다. `hosts`·`authHosts`에는 `*`를 허용하지 않습니다.

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
  원격 파일의 **기기에 다운로드**도 이 훅과 기존 인증 규약을 사용합니다. 재개할 때 새 URL을 얻고 파일 내용·확장자를 그대로 저장하므로 별도 다운로드 훅이나 확장앱 업데이트는 필요 없습니다. `list`의 파일 이름·크기를 정확하게 반환하고 `stream`은 HTML 페이지가 아닌 실제 파일 주소를 반환해야 합니다.
- 선택적 `canDelete: true` 메타데이터와 `async delete({path,name,isDir})`를 함께 선언하면 목록에 스와이프 삭제 버튼이
  표시됩니다. 실제 서버 삭제가 성공한 뒤 정확히 `true`를 반환해야 합니다. 루트는 삭제할 수 없고, 응답 없는 함수·실패·
  부분 실패는 성공으로 처리하지 않습니다. 폴더 하위 항목 삭제는 확장앱이 처리하며 사용자의 쓰기 권한이 필요합니다.
  클라우드 ID에는 경로 계층 정보가 없어 폴더 삭제 전 해당 계정에 등록된 리소스 잠금을 모두 확인합니다.
  HTTP DELETE 등의 인증 요청은 기존 도메인·비밀값 전송 제한을 따릅니다. 기본 공식 클라우드 확장앱과 DLNA는 읽기 전용이며,
  이 선언만으로 OAuth 권한이나 S3의 읽기 전용 서명 범위를 넓히지는 않습니다. 권한·지원 여부를 확인한 확장앱만 선언하세요.
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

### HTML·XML·JSON 파서 (API 3, v0.1.3 이상)

클라우드 함수·사이트의 `resolveDownload`·WebView `page`에서 같은 `OPlayer.parse` 인터페이스를 사용합니다.
앱 측 HTML 파서는 Dart 공식 [html](https://pub.dev/packages/html), XML은 기존
[xml](https://pub.dev/packages/xml), JSON은 JS 표준 `JSON.parse`를 사용합니다.
페이지 훅은 WebView의 `DOMParser`를 사용하며 파싱한 노드를 현재 페이지에 삽입하지 않습니다.
앱 측 파서는 스크립트를 실행하거나 외부 주소·DTD·엔티티를 읽지 않습니다.

```javascript
const text = await OPlayer.request('https://example.com/files', {response:'text'});
const html = await OPlayer.parse.html(text);
const links = await html.querySelectorAll('a.media[href]');
const files = links.map(a => ({name:a.textContent.trim(), url:a.getAttribute('href')}));
const first = await html.querySelector('#featured'); // 없으면 null
await html.dispose();

const xml = await OPlayer.parse.xml('<feed xmlns:m="urn:media"><m:item id="1"><![CDATA[A < B]]></m:item></feed>');
const items = await xml.findAllElements('item', 'urn:media');
const name = items[0].textContent;
const id = items[0].getAttribute('id');
await xml.dispose();

const json = OPlayer.parse.json('{"files":[{"name":"video.mp4"}]}');
const fileName = json.files[0].name;
```

- `html(text)`·`xml(text)`와 모든 노드 조회는 `await`합니다. `json(text)`는 동기 함수이며 객체·배열·원시 값을 반환합니다.
- 문서·노드는 읽기 전용입니다. `name`, `localName`, `namespaceUri`, `attributes`, `textContent`,
  `getAttribute(name)`을 제공합니다. 없는 속성은 `null`입니다. 상대 URL은 자동으로 절대 URL로 바꾸지 않습니다.
- HTML: `querySelector(css)`·`querySelectorAll(css)`로 하위 요소를 찾습니다. 태그·ID·클래스·속성·자식/후손
  선택자를 지원합니다. 브라우저의 모든 최신 CSS 의사 선택자가 앱 측 파서에 구현되어 있지는 않습니다.
- XML: `findElements(name, namespace = null)`는 직접 자식, `findAllElements(name, namespace = null)`는 모든
  하위 요소를 찾습니다. namespace 생략 시 `m:item` 같은 한정 이름으로, URI 지정 시 로컬 이름+URI로 찾습니다.
  이름·namespace의 `'*'`는 와일드카드입니다. CDATA·표준 엔티티·네임스페이스를 보존하며 DTD 선언은 거부합니다.
- 공통: `children()`은 직접 자식 요소 배열을 반환합니다. `dispose()`는 해당 문서와 모든 자식의 핸들을 폐기합니다.
  앱 측 문서는 JS 호출 종료 시에도 자동으로 정리됩니다. 페이지 훅은 조회를 마친 뒤 직접 폐기하세요.
- 입력은 문서당 1Mi UTF-16 코드 단위, HTML/XML은 호출당 최대 16문서·총 8Mi 코드 단위·문서당 20,000노드·깊이 128입니다.
  조회 결과는 최대 2,000개·직렬화 JSON 2Mi 코드 단위, 선택자는 1,024자입니다. 초과·문법 오류는 예외로 처리합니다.
  앱 측 파서 호출도 HTTP·암호 연산과 합쳐 최대 200회·60초 제한을 따릅니다.
- 기존 `response:'xml'`의 `{name,children,text?}` 응답은 그대로 유지합니다. 새 조회 API를 쓰려면
  `response:'text'`로 받은 뒤 파싱하세요. [실행 가능한 예제](examples/site.parser.example.js)와
  `test/plugin_parser_test.dart`에서 HTML 다운로드 보완·XML·JSON·실패 처리를 확인할 수 있습니다.

앱 측 실행은 호출마다 새 QuickJS 런타임을 사용합니다. 한 번의 JS 실행·Promise 루프는 200ms,
힙은 32MB, 호출 전체는 60초·최대 200개 요청으로 제한합니다. 로컬 파일·네이티브 API는 노출하지 않습니다.
WebView의 `page` 함수는 이 실행 제한 밖에서 해당 페이지의 사용자 스크립트로 실행됩니다.
페이지·요청 헤더에 접근하는 확장앱이므로 신뢰하는 개발자의 코드만 설치하세요.

### 자막 검색 (API 4)

`kind: "player", capabilities: ["subtitles"]` 확장앱은 브라우저에 주입하지 않습니다. 기존 사이트·클라우드와 같은
도메인 권한, 공통 설정 UI, OS 보안 저장소와 `OPlayer.request`·파서 SDK를 사용합니다.
필수 함수는 `searchSubtitles`와 `downloadSubtitle`이며 설치 시 둘 다 검사합니다.
공식 구현은 [subtitle.opensubtitles.js](subtitle.opensubtitles.js)를 참고하세요.

```js
// @oplayer {"api":4,"id":"subtitle.example","name":"Example subtitles","version":"1.0.0","kind":"player","capabilities":["subtitles"],"hosts":["subtitles.example.com"],"settings":[]}
globalThis.plugin = {
  async searchSubtitles({query, language, page = 1}) {
    const response = await OPlayer.request('https://subtitles.example.com/search', {
      query: {q: query, language, page: String(page)}
    });
    return {
      items: response.results.map(row => ({
        id: String(row.id), title: row.name, language, release: row.release,
        data: {fileId: row.fileId} // provider-owned data passed back on selection
      })),
      totalPages: response.totalPages
    };
  },
  async downloadSubtitle({item}) {
    const response = await OPlayer.request('https://subtitles.example.com/download', {
      method: 'POST', body: {id: item.data.fileId}
    });
    return {url: response.url, format: 'srt'};
    // Or return {content: 'subtitle text', format: 'srt'}.
  }
};
```

- 입력 `query`는 편집 가능한 영상 제목, `language`는 `ko`·`en`·`ja` 등의 언어 코드,
  `page`는 1부터 시작하는 페이지입니다. 로컬 경로·미디어 인증 헤더는 전달하지 않습니다.
- 결과 `items`는 페이지당 최대 100개입니다. `id`(최대 200자)와 `title`(최대 512자)은 필수 문자열이며,
  `language`·`release`는 표시용 선택 항목입니다. `data`는 선택된 항목과 함께 다운로드 함수에 전달됩니다.
- 다운로드 함수는 `url`과 선택적 `headers` 또는 자막 본문 `content`를 반환합니다.
  `format`은 `srt`·`smi`·`ass`·`ssa`·`vtt`·`lrc`·`sub`이며 기본은 `srt`입니다. 파일명은 호스트가 정하고
  크기는 8MiB로 제한합니다. HTML 오류 페이지와 ZIP 묶음은 자막으로 적용하지 않습니다.
- URL은 `hosts`/`networkSettings` 권한 안에 있어야 합니다. 비밀값 참조는 `authHosts`/`authSettings`에만
  보낼 수 있습니다. 리디렉션도 매번 권한을 확인하며, 출처가 바뀌면 모든 요청 헤더를 제거합니다.
- 공통 설정의 `language`(기본 `ko`)와 `autoApply`(기본 false)를 선언하면 재생 시작 시 자동 적용에
  참여합니다. 사용할 내장·외부 자막이 있으면 자동 검색을 건너뛰며, 첫 번째로 활성화된 자동 적용 공급자에서
  첫 결과를 선택합니다. 자동 적용 순서가 중요하면 확장앱이 결과를 정렬해야 합니다.
- API Key·비밀번호는 `type: "password"`로 선언하고 `OPlayer.secret`으로 참조합니다. 로그인·다운로드 URL 발급과
  서비스별 오류 처리는 JS에서 구현합니다. 자막 파일은 현재 재생 세션의 임시 파일로 관리됩니다.
- 기본 OpenSubtitles는 첫 도입 시 추가되며 사용자가 삭제·비활성화할 수 있습니다. 삭제 후 매 실행마다
  다시 설치하지 않습니다. 1.0.1부터 API Key만으로 로그인 없이 검색·다운로드하며 사용자 이름·비밀번호는
  선택 사항입니다. 계정을 입력하면 해당 계정으로 로그인합니다. 로그인 실패 시 익명 다운로드로 자동 전환하지
  않으며 다운로드 POST를 자동 재전송하지 않습니다. 키 발급과 할당량은 [공식 API 안내](https://opensubtitles.tawk.help/article/getting-started)를 따릅니다.

## 테스트

앱을 한 번 빌드하거나 테스트용 엔진을 먼저 컴파일하세요. Windows:

```sh
cmake -S packages/quickjs_engine/native -B build/plugin-runtime -A x64
cmake --build build/plugin-runtime --config Release --parallel 4
flutter test --no-pub
```

Linux/macOS는 `cmake -S ... -B ...`에서 `-A x64`를 빼고 같은 위치에 빌드합니다.
`LIBQUICKJSC_TEST_PATH`로 DLL/공유 라이브러리 경로를 직접 지정할 수도 있습니다.
