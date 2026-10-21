# OPlayer

Android · Android TV · iOS · Windows · Linux · macOS 동영상 플레이어 (Flutter + media_kit/libmpv).
nPlayer의 UI/UX를 기준으로, 로컬·네트워크·클라우드 재생과 웹 페이지 동영상 받기를 지원한다.

## 실행

```bash
flutter pub get
flutter run -d windows   # 또는 macos / android / ios
```

- Flutter 3.35+ (Dart 3.9)
- **Windows**: 개발자 모드 켜기(플러그인 심볼릭 링크), WebView2 런타임(Win11 기본 포함),
  `nuget.exe`가 PATH에 있어야 함(flutter_inappwebview_windows). VS 2026(MSVC 14.5x)용으로
  `windows/CMakeLists.txt`에 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` 정의 추가됨.
- `pubspec.yaml`의 `dependency_overrides: pointycastle ^4` — smb_connect(^3 고정)와 dartssh2 4.x 충돌 해소용.
- **Android**: minSdk 24. 폴더 탐색을 위해 "모든 파일 접근" 권한을 요청한다.
  - 빌드 환경(미니PC): JDK 17 `D:\Apps\jdk-17`, Android SDK `D:\Apps\Android\Sdk`
    (platform-tools, platforms 36/37, build-tools 36, NDK 28.2.13676358, cmake 3.22.1) — `flutter config`에 등록됨
  - Gradle 8.14.3 / AGP 8.11.1 / Kotlin 2.2.20, Java 17. `kotlin.incremental=false`(C:/D: 드라이브 분리 문제)
  - `flutter build apk --release --flavor mobile --split-per-abi` → `build/app/outputs/flutter-apk/` (배포용 키 서명)
  - Android TV는 `--flavor tv`로 별도 빌드한다. 패키지 ID는 `com.oplayer.oplayer.tv`이고 같은 배포 키를 사용한다. TV 런처·Leanback 배너와 터치스크린 비필수 설정을 포함하며, 리모컨 조작은 실제 TV 기기에서 별도 검증이 필요하다.
  - 릴리스 서명: `android/key.properties`의 로컬 설정과 `android/keystores/oplayer-release.p12`를 사용한다. 둘 다 비공개 파일이며 저장소와 APK에 포함하지 않는다. 이 두 파일은 안전한 별도 위치에도 백업하고, 이후 업데이트마다 같은 키를 사용해야 한다. 키 또는 설정이 없으면 릴리스 빌드를 중단하며 디버그 키로 대체하지 않는다. 디버그 빌드는 기존 개발용 키를 유지한다.
  - 기존 디버그 서명 앱에는 새 배포용 서명 APK를 덮어설치할 수 없다. 최초 전환 시 데이터와 다운로드 파일을 보존한 뒤 기존 앱을 제거하고 설치해야 한다. 배포용 키는 Google Play 심사·개발자 인증 또는 Play Protect 검사 면제를 의미하지 않는다.
- **iOS**: 앱 Documents 폴더가 기본 루트 (파일 앱 → OPlayer 폴더). Podfile `platform :ios, '13.0'` 이상.
- **Linux**: `flutter build linux --release`. GTK 러너와 Linux 플러그인 빌드에 필요한 패키지는 Actions의 Linux 단계에 명시한다.
- **macOS**: macOS 12 이상, CocoaPods, `flutter build macos --release`. 샌드박스 권한(네트워크 클라이언트/서버, 사용자 선택 파일, 다운로드 폴더) 설정됨. CI는 로컬 ad-hoc 서명으로 빌드를 검증하며 Apple Developer ID 서명·공증은 포함하지 않는다.

## GitHub Actions 빌드와 릴리스

- 브랜치 push·PR·버전 번호 변경만으로는 빌드하지 않는다. 사용자가 배포를 지시할 때만 해당 커밋에 `v0.1.1` 같은 버전 태그를 만들고 push한다. `v*` 태그 push를 받으면 Windows, Android(mobile), Android TV(tv), Linux(x64), macOS(Apple Silicon 러너)를 빌드한다. Android·TV는 같은 배포 키로 각각 서명하며 Windows에서 정적 분석·Dart 테스트·브라우저 JavaScript 테스트도 실행한다.
- 다섯 빌드와 검증이 모두 성공하면 push된 태그에 GitHub Release와 배포 파일을 등록한다. 태그와 `pubspec.yaml` 버전이 다르면 게시를 거부한다. Actions는 태그를 생성하거나 이동하지 않는다. 기존 버전 교체도 사용자 지시가 있을 때만 해당 태그를 대상 커밋으로 갱신·push하며, 이 경우 같은 이름의 배포 파일을 교체한다.
- v0.1.1 이후 릴리스부터는 태그를 만들기 전에 `CHANGELOG.md`에 `## [버전]` 제목으로 추가 기능·수정 사항·알려진 제한을 정리한다. Actions는 해당 버전의 내용을 릴리스 본문 맨 위에 게시하며, 노트가 누락되면 게시를 거부한다. 일반 코드 push에서는 빌드하지 않는다.
- GitHub Release에 Android·Android TV의 ABI별 서명 APK 6개, Windows x64 ZIP, Linux x64 tar.gz, macOS Apple Silicon ZIP과 SHA256SUMS.txt를 첨부한다. 데스크톱 압축 파일은 실행 파일·라이브러리·데이터를 포함하므로 전체를 풀어 사용한다. 빌드 작업 간 전달용 Actions 아티팩트는 7일 동안 보관한다.
- 저장소 Actions Secrets에 `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`를 등록한다. 키와 비밀번호는 빌드 중 임시 복원 후 삭제하며, 저장소·릴리스에 커밋하거나 업로드하지 않는다.
- 기본 `main`의 `LICENSE`는 `devel`과 `main`에서 그대로 유지한다. `third_party/`의 외부 구성요소는 각 디렉터리의 라이선스도 함께 적용된다.

## 기능

| 영역 | 내용 |
|---|---|
| 로컬 | 폴더 탐색, 폴더 추가, 정렬(이름·날짜·크기, 자연 정렬), 목록/격자, **썸네일 캐시**, 이어보기 진행바 |
| 네트워크 | **SMB**(Dart SMB 클라이언트 → 로컬 HTTP Range 프록시), **FTP/FTPS**(ftp:// 직접), **SFTP**(비밀번호/개인 키, 호스트 키 고정 → 프록시), **WebDAV**(http(s)+Basic 인증), **UPnP/DLNA** 자동 검색 |
| 클라우드 | **Google Drive / Dropbox / OneDrive** — 앱 등록 설정, 로그인, 토큰 자동 갱신, 폴더 탐색, 스트리밍 재생 |
| 웹 | 내장 브라우저(북마크), 페이지 내 동영상 자동 감지(video 태그·fetch/XHR·리소스 로드), 바로 재생 / 다운로드 |
| 다운로드 | mp4·webm 등 직접 파일 이어받기, **HLS(m3u8)** 최고 화질 선택·병렬 조각 받기·AES-128 복호화·병합(.ts / fMP4는 .mp4), 일시정지/재개 |
| 플레이어 | 제스처(탐색·밝기·볼륨·핀치·더블탭·길게 눌러 2배속), 잠금, 화면비, 배속, A-B 반복, 자막 트랙/싱크/크기, 오디오 트랙, 재생목록, 단축키 |
| 공통 | 최근 재생(로컬·원격 모두 다시 열기), 설정 화면, 비밀번호/토큰은 OS 보안 저장소 |

DRM(Widevine/FairPlay, SAMPLE-AES)으로 보호된 스트림은 재생·다운로드 대상이 아니다.

### 추가된 재생·탐색 기능

- 로컬·네트워크·클라우드 폴더는 경로별로 정렬 기준(이름·날짜·크기), 오름차순/내림차순, ‘폴더 먼저 표시’를 기억한다. 정렬 메뉴에서 변경하면 즉시 저장되어 폴더 재방문과 앱 재시작 후에도 복원되며, 서버와 하위 폴더별로 독립 적용된다.
- 앱 복귀 후 현재 폴더 목록은 자동 재조회한다. 앱 잠금이 있으면 해제를 기다리고, 리소스 잠금은 재조회 전에 별도로 인증한다. 네트워크 목록은 캐시를 건너뛰며, 잠긴 리소스를 수동 해제한 뒤에도 목록을 다시 불러온다. 다른 화면 뒤에 가려진 폴더는 해당 화면으로 돌아올 때 갱신한다.
- Android 8 이상 PiP: 플레이어 버튼 또는 재생 중 홈으로 이동. 작은 창에는 `10초 뒤로 · 재생/일시정지 · 10초 앞으로` 세 버튼만 표시한다.
- Android 미디어 알림과 잠금 화면에서는 10초 탐색·재생/일시정지·이전/다음 파일 조작을 제공한다. 헤드셋 버튼과 조작 묶음 전환은 사용하지 않는다. 오디오 전용 파일은 앨범 표지 유무와 관계없이 홈 이동 후에도 재생하고, 영상은 PiP 또는 백그라운드 설정을 따른다. 이어폰 분리 시에는 일시정지한다.
- Android 다운로드는 진행 알림이 있는 dataSync 포그라운드 서비스와 CPU 절전 방지 잠금으로 홈 이동·화면 꺼짐 중 작업을 유지한다. Android 13 이상은 첫 다운로드 때 알림 권한을 요청한다. 알림에서 다운로드 목록 열기·전체 일시정지를 지원하고 완료·실패도 표시한다. 앱 강제 종료·최근 앱에서 작업 제거 시에는 계속 실행하지 않으며, Android의 서비스 시간 제한 시 안전하게 일시정지한다. 실제 기기와 제조사별 절전 정책 검증은 별도로 필요하다.
- Android에는 FFmpeg를 내장하여 HLS 수신 후 MP4로 스트림 복사하고 분리된 영상·음성을 병합한다. 별도 설치는 필요 없다. Windows/macOS/Linux는 설정에서 외부 FFmpeg를 자동 탐색하거나 지정한다.
- Chromecast(Android)·DLNA 외부 출력: 같은 네트워크 기기 검색, 탐색·재생/일시정지·볼륨·종료. 로컬 파일과 HTTP 기반 네트워크 소스를 Range 지원 릴레이로 전달한다. FTP 직접 출력은 지원하지 않으며 먼저 로컬 파일로 받아야 한다.
- 오디오 싱크·증폭·10밴드 EQ, 영상 회전·반전·색상 조정, 자막 파일 선택·위치·크기·싱크, 종료 타이머·화면 캡처. 효과 적용 여부는 재생 엔진에 따라 달라진다.
- 브라우저 휠 이동량 40% 적용(파일 목록 휠은 유지), Android/iOS 브라우저와 로컬·네트워크 파일 목록에서 당겨서 새로고침.
- Android·Windows 설정 → 앱 네트워크: DoH와 ByeDPI 각각 켜기/끄기, HTTPS DoH 쿼리 URL 지정·저장. 내장 브라우저와 HTTP(S) 다운로드·재생에 적용하며, NAS 등 내부 주소와 FTP/SMB/SFTP·외부 출력 기기 자체 통신에는 적용하지 않는다. 설정을 바꾸면 웹페이지를 새로고침하고 영상을 다시 연다.
- DoH는 RFC 8484 `application/dns-message` POST를 사용한다. DoH 서버의 최초 주소 조회에는 시스템 DNS를 사용하고, 조회 실패 시 일반 DNS로 재시도하지 않는다. ByeDPI v0.17.3 엔진은 앱이 실행·종료를 관리하며 TLS 인증서 검증은 그대로 유지한다. Android는 프록시 설정을 지원하는 System WebView가 필요하다.
- HLS 요청 헤더 재사용, 브라우저에서 받은 재생목록 보존, identity AES-128 키 교체 구간을 페이지의 기존 키 로더로 미리 준비. 사이트 전용 JSON의 암호화된 필드를 원시 AES 키로 사용하지 않는다.

Chromecast·DLNA·PiP는 실제 Android/TV 기기 검증이 필요하다. nPlayer의 모든 기능과 일치하는 구현은 아니며 AirPlay 송신·NFS는 포함하지 않는다.

## 클라우드 설정 (필수)

설정 → 클라우드 계정 연결에서 OneDrive의 Application (client) ID 또는 Dropbox의 App Key를 입력한다. 첫 연결 시에도 등록 안내가 열린다. 앱 비밀키나 사용자 비밀번호를 APK에 넣지 않는다. 앱 개발자가 공통 키를 지정하려면 `--dart-define=ONEDRIVE_CLIENT_ID=...` / `--dart-define=DROPBOX_APP_KEY=...`로 빌드할 수도 있다.

- OneDrive: Microsoft Entra 앱 등록에서 개인 Microsoft 계정을 포함하는 계정 유형과 모바일 및 데스크톱 플랫폼을 선택한다. 권한은 Files.Read, User.Read, offline_access. 커스텀 복귀 주소 `com.oplayer.oplayer://oauth/onedrive`와 데스크톱 `http://localhost:53682/callback`을 등록한다.
- Dropbox: Scoped access / Full Dropbox 앱을 만들고 files.metadata.read, files.content.read, account_info.read 권한을 켠다. `com.oplayer.oplayer://oauth/dropbox`와 `http://localhost:53682/callback`을 등록한다.
- Google Drive: Google Cloud 프로젝트에서 Drive API를 사용 설정하고 OAuth 동의 화면에 `https://www.googleapis.com/auth/drive.readonly`와 테스트 사용자를 추가한다. 파일·폴더 탐색 및 미디어 읽기 전용이며 업로드·수정 권한은 요청하지 않는다. Windows/macOS/Linux에서는 **데스크톱 앱** 유형의 Client ID와 Client Secret을 설정에 입력한다. Secret은 기기의 보안 저장소에 계정이 사용한 Client ID별로 보관하며 APK나 일반 설정 파일에 넣지 않는다. 로그인은 시스템 브라우저와 `http://127.0.0.1:53682/callback` 루프백, PKCE로 처리한다.
- Google Drive Android/Android TV: **Android** 유형의 OAuth 클라이언트를 만든다. 앱 등록 화면에 표시되는 현재 패키지와 서명 SHA-1을 그대로 등록하고 Client ID를 입력한다. 모바일 `com.oplayer.oplayer`와 TV `com.oplayer.oplayer.tv`, 디버그/배포 서명은 각각 등록한다. Google Play 서비스의 공식 Authorization SDK를 사용하며 Android 루프백·커스텀 스킴은 사용하지 않는다. TV도 Google Play 서비스 및 계정·동의 UI가 필요하다. iOS의 Google Drive 연결은 지원하지 않는다.
- `drive.readonly`는 제한된 범위이므로 공개 배포 로그인에는 Google OAuth 검증이 필요하다. 외부 테스트 모드에서는 등록한 테스트 사용자만 접속할 수 있고 갱신 토큰이 7일 후 만료될 수 있다. [Google OAuth 안내](https://developers.google.com/identity/protocols/oauth2/native-app), [Android 인증 안내](https://developer.android.com/identity/authorization), [Drive 권한 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
- Android/iOS 복귀 스킴은 이미 등록되어 있다. Windows/macOS/Linux는 시스템 브라우저와 루프백 콜백을 사용한다. PKCE S256, state, 복귀 주소를 검증하고 토큰은 보안 저장소에 보관한다.
- 연결된 계정은 당시의 앱 ID를 유지하므로 설정에서 다른 앱 ID를 입력해도 기존 계정의 갱신 정보가 바뀌지 않는다. 연결 해제 시 로컬 토큰을 삭제한다. 서비스 웹사이트의 전체 로그인 세션을 종료하는 동작은 아니다.
- 실제 앱 등록 ID와 사용자의 동의가 있어야 로그인할 수 있다. 자동 테스트는 로컬 OAuth 콜백·모의 공급자 응답으로 검증하며, 실계정과 실제 Android 기기 테스트는 별도로 필요하다.

## Windows 기본 미디어 플레이어

Windows 버전을 실행하면 현재 실행 파일 경로를 사용자별 기본 앱 후보와 ‘연결 프로그램’ 목록에 등록한다. 설정 → 재생 → **Windows 기본 미디어 플레이어로 설정**에서 Windows 기본 앱 설정을 열어 OPlayer와 원하는 동영상·음악 확장자를 선택한다. 관리자 권한은 필요 없으며 기존 기본 앱 선택은 자동 변경하지 않는다. 탐색기에서 연결된 파일을 열면 해당 경로를 전달받아 재생하고, 앱 잠금이 켜져 있으면 해제 후 연다. ZIP 배포 폴더를 옮겼다면 새 위치에서 OPlayer를 한 번 실행해 등록 경로를 갱신한다.

## 리소스 잠금·캡처 방지

- 설정 → 개인정보 보호 → 공통 잠금 정보 등록에서 숫자 6자리 PIN 또는 3×3 패턴(4개 이상)을 선택한다. 등록한 PIN·패턴을 앱 잠금과 모든 파일·폴더·네트워크 저장소 잠금에서 공유한다. PIN과 패턴을 함께 등록할 수 있고 각각 삭제할 수 있다. PIN만 삭제하면 패턴과 생체인증 및 잠금 대상은 유지된다. 마지막 잠금 정보는 앱·리소스 잠금을 모두 끈 뒤 삭제할 수 있다.
- 리소스별로 잠금 대상을 선택한다. 잠금 정보는 공통이지만 해제 상태는 앱과 리소스별로 분리된다. A를 해제해도 B와 별도로 잠근 하위 폴더는 잠긴 상태다. 일반 하위 항목은 부모 폴더의 해제 상태를 따른다. 앱 잠금은 별도로 켜고 끌 수 있으며, 리소스 잠금만 설정하면 로컬 홈은 자동으로 잠기지 않는다.
- 사이드바의 로컬 홈·등록 폴더·최근 재생 `⋯` 메뉴에서 잠금을 설정한다. 최근 재생 화면 상단에서도 목록 전체를 잠글 수 있고, 항목의 `⋮` 메뉴에서 파일별 잠금을 설정한다. 목록 전체를 잠그면 기록·경로·썸네일이 가려진다. 최근 재생 목록의 인증은 별도로 잠근 파일이나 폴더에 대한 접근 권한을 부여하지 않는다.
- 백그라운드 진입이나 수동 다시 잠그기는 모든 리소스의 해제 상태를 지운다. 보호 폴더·사진·영상 화면은 가리되, 백그라운드 전환 전에 승인된 현재 미디어 재생은 유지한다. 새 보호 파일 접근에는 다시 인증해야 하며, 수동 다시 잠그기나 리소스 잠금 변경은 기존 재생 승인도 회수한다.
- Android 지문·생체인증과 Windows Hello를 공통 해제 수단으로 사용할 수 있다. 생체인증 취소 시 등록한 PIN 또는 패턴으로 해제한다. 잠금 정보와 보안 설정 변경 시에는 등록된 기본 PIN 또는 패턴을 다시 확인한다.
- PIN·패턴은 임의 salt와 PBKDF2-HMAC-SHA256 210,000회로 검증하고 OS 보안 저장소에 보관한다. Android 8 이상과 Windows는 백그라운드 네이티브 연산을 사용하고 구형 Android는 Dart 작업 isolate로 같은 형식을 검증한다. 검증 중에는 진행 표시를 제공한다. 정상 인증 시 변경 없는 저장소 재기록을 생략한다. 잘못된 입력 5회 후 30초 제한한다. 기존 PIN+패턴 등록 정보도 유지한다. 파일 자체는 이동·암호화하지 않는다.
- 앱 잠금을 켜면 앱 시작·백그라운드 복귀 시 공통 잠금 정보를 확인하며 사용 중에도 캡처 방지를 강제 적용한다. 생체인증이 켜져 있으면 앱·리소스 잠금 해제와 설정 확인에서 지문 또는 Windows Hello를 먼저 요청하고, 취소·실패 시 등록된 PIN·패턴을 표시한다.
- 캡처 수동 설정 스위치는 앱 잠금 중에도 변경·저장할 수 있다. 현재 실제 차단 상태를 별도로 표시한다. 앱 잠금 사용 중에는 잠금 해제 후에도 항상 차단하고, 앱 잠금을 끄면 저장된 수동 설정을 따른다. Android는 `FLAG_SECURE`, Windows는 [SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)를 사용한다. 플레이어 자체 화면 저장에도 동일한 정책을 적용한다.
- Windows Hello는 앱 창의 HWND를 지정하는 공식 [UserConsentVerifier interop](https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier)으로 인증한다. `flutter run -d windows --debug --no-pub -t tool/privacy_native_smoke.dart`로 실제 캡처 차단 값과 Hello 사용 가능 여부를 확인한다. 실제 지문·Hello 승인과 Android 화면 차단은 실기기 확인이 필요하다.

## Android WebView와 HTTPS 필터링

Android는 시스템 인증서와 사용자가 기기에 설치한 CA 인증서를 신뢰한다. AdGuard HTTPS 필터링을 사용하려면 AdGuard CA가 기기의 사용자 인증서 저장소에 설치되어 있어야 한다. 이 신뢰 설정은 WebView 외 Android 네트워크 API에도 적용될 수 있으며, 호스트명·유효기간·인증서 체인 검증은 유지한다. 내장 브라우저의 감지된 동영상 → 요청 기록에서 리소스 로드 실패·HTTP 오류를 확인할 수 있다.

## 구조

```
lib/
  main.dart
  app/theme.dart
  core/
    media_item.dart        재생 항목(URI·헤더·자막·지연 resolve)
    settings.dart          앱 설정 (SharedPreferences)
    resume_store.dart      이어보기·최근 재생·추가 폴더
    secure_store.dart      비밀번호/토큰 (flutter_secure_storage)
    stream_proxy.dart      127.0.0.1 HTTP Range 프록시 (SMB 재생용)
    thumbnail_service.dart 로컬 썸네일 생성·캐시
    media_utils.dart
  sources/
    media_source.dart      공통 인터페이스 (list / itemFor / itemForPath)
    server_store.dart      서버·클라우드 계정 목록
    source_registry.dart   설정 → 소스 인스턴스, 최근 재생 키 → 재생 항목
    smb_source.dart  ftp_source.dart  sftp_source.dart  webdav_source.dart  dlna_source.dart
    cloud/ cloud_config.dart  oauth.dart  cloud_sources.dart
  features/
    browser/   home_screen(사이드바) · local_browser_page · recent_page · video_tile
    network/   remote_browser_page · server_edit_dialog · dlna_page
    web/       web_browser_page · download_manager · hls · downloads_page
    settings/  settings_page
    player/    player_controller · player_screen · widgets/(gesture_layer, controls_overlay, seek_bar, side_panels)
test/          홈/설정 위젯 테스트, HLS 파서·AES·프록시 단위 테스트
```

## 플레이어 조작

| 제스처 | 동작 |
|---|---|
| 탭 | 컨트롤 표시/숨김 |
| 더블탭 좌/우 | N초 뒤로/앞으로 (설정, 연속 탭 누적) |
| 더블탭 가운데 | 재생/일시정지 |
| 좌우 스와이프 | 탐색 (손 떼면 이동, 미리보기) |
| 왼쪽/오른쪽 상하 스와이프 | 밝기 / 볼륨 |
| 핀치 | 확대/축소 |
| 길게 누르기 | 2배속 |

| 키 | 동작 |
|---|---|
| Space / K | 재생·일시정지 |
| ← → (Shift: 1분) / J L | 탐색 |
| ↑ ↓ / 휠 | 볼륨 |
| [ ] / Backspace | 배속 / 1.0x |
| , . | 자막 싱크 |
| N P | 다음 / 이전 |
| A / R | 화면비 / A-B 반복 |
| Esc | 패널 닫기 / 나가기 |

## 남은 작업

- 실기기 검증 (특히 SMB 대용량 탐색 성능, inappwebview Windows 감지 범위)
- 데스크톱 전체화면(window_manager), PiP, 백그라운드 재생
- Plex/Jellyfin API 연동, 클라우드 공유 드라이브 목록

- DoH·ByeDPI는 내장 브라우저·다운로드 기능에 한 묶음으로 적용한다. 등록한 리소스에도 적용 스위치로 WebDAV·클라우드 등의 HTTP(S) 리소스 연결 포함 여부를 별도로 정한다. 브라우저에서 시작한 미디어 재생(최근 재생 포함)은 브라우저 범위를 따른다. SMB·FTP·SFTP와 내부 네트워크는 직접 연결한다.
- 폴더 안에서도 뒤로가기와 메뉴 버튼을 함께 제공하며 서버 연결 중에도 메뉴를 열 수 있다.

- 브라우저에서 감지한 HLS·일반 영상의 내장 플레이어 재생도 브라우저 다운로드와 같은 세션·요청 헤더를 사용한다. 로컬 재생 연결을 통해 HLS 재생목록/오디오/초기화 조각/키 URI를 변환하고, 관찰된 identity AES-128 키를 메모리에서만 전달한다. 네이티브 HTTP 401/403 시 다운로드에 사용하는 브라우저 전송으로 재요청하며 일반 영상의 Range 요청도 전달한다.
- 재생 종료·항목 전환 시 로컬 연결과 해당 세션의 키 복사본을 정리한다. 최근 웹 영상의 브라우저 요청 정보는 실행 중 메모리에서만 제한적으로 유지하며, 앱 재시작 후 인증·만료된 웹 영상은 페이지를 다시 열어야 한다. DRM은 지원하지 않는다.
- 브라우저 재생 준비·수신 실패는 플레이어에 표시하고 시작 시 60초 동안 데이터가 없으면 오류로 종료한다. `tool/browser_playback_smoke.dart`는 사용자 저장 정보를 읽지 않고 로컬 생성 암호화 영상의 403 재요청과 실제 재생 엔진 복호화를 검증한다.
