# OPlayer 확장앱

설정 → **확장앱**에서 저장소를 추가하고 목록을 확인한 뒤 설치합니다.
확장앱은 `.js` 파일이며 APK·앱 재설치 없이 로드합니다. JS 파일 직접 가져오기도 지원합니다.
현재 SDK는 JavaScript API 1이며 Dart 소스·Flutter 위젯·네이티브 코드를 동적으로 로드하지 않습니다.

공식 저장소 JSON:
https://raw.githubusercontent.com/gaeco0/OPlayer/main/plugins/repository.json

Google Drive·Dropbox·OneDrive는 공식 확장앱으로 제공됩니다. 기존 계정·토큰·리소스 키는 유지됩니다.
기존 동작을 유지하도록 첫 시작에 기본 클라우드 확장앱을 포함하며 삭제 후 저장소에서 다시 설치할 수 있습니다.

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
`id`, `name`, `version`, `api: 1`, `kind: "site" | "cloud"`를 지정합니다.
도메인은 정확한 호스트 또는 `*.example.com` 형식입니다. 와일드카드는 하위 호스트만 포함합니다.

### 사이트 기능

[examples/site.example.js](examples/site.example.js)는 실제로 로드 가능한 예제입니다.

- `sites`: 스크립트를 실행하고 미디어를 보완할 페이지 도메인.
- `hosts`: 앱에서 `OPlayer.request`로 호출할 수 있는 HTTPS 도메인.
- `blockRules: [{"urlFilter": "정규식"}]`: 해당 사이트의 네트워크 요청 차단 규칙.
- `page(api)`: WebView에서 실행. DOM을 읽고 `api.reportMedia(url, hint)`로 미디어를 보고합니다.
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
추가 공급자는 Client ID를 연결 시 입력합니다.

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
