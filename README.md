# OPlayer

[홈페이지](https://gaeco0.github.io/OPlayer/) · [개인정보처리방침](https://gaeco0.github.io/OPlayer/privacy.html) · [이용약관](https://gaeco0.github.io/OPlayer/terms.html)

Android · Android TV · iOS · Windows · Linux · macOS 동영상 플레이어 (Flutter + media_kit/libmpv).
nPlayer의 UI/UX를 기준으로, 로컬·네트워크·클라우드 재생과 웹 페이지 동영상 받기를 지원한다.

- 설정에서 브라우저 홈페이지, 다운로드 출력 화질, Primary·Secondary 색상, 시스템·밝은·어두운 테마를 선택합니다.
- 다운로드 목록도 공통 PIN·패턴·생체인증으로 잠글 수 있으며, 보호된 작업의 파일명은 알림에서 숨깁니다.
- 클라우드·사이트 다운로드 보완·광고 차단을 앱 내 확장앱으로 제공합니다. 저장소 JSON URL 추가와 JS 파일 가져오기를 지원합니다.
  공식 저장소 형식과 개발 API는 [확장앱 문서](plugins/README.md)를 참고하세요.
- 확장앱 공통 설정·인증 SDK와 HTML·XML·JSON 파서(API 3)를 제공합니다. 같은 SDK로 새 공급자를 추가할 때 앱을 다시 빌드할 필요가 없습니다.
- v0.1.5는 확장앱을 플레이어·브라우저·리소스 세 유형으로 분류하고 유형별 기능을 검사합니다. 같은 API 4 규약의 새 자막 공급자·영상 색상 필터·사이트·스토리지는 앱 업데이트 없이 JS와 저장소 JSON만으로 배포합니다.
- 공식 저장소에서 **disable-devtool 차단** 브라우저 확장앱을 선택 설치할 수 있습니다. 1.1.0부터 모든 웹사이트와 교차 도메인 iframe에 적용되며 켠 뒤 새로고침합니다. 콘솔 억제 설정·변형 대응 제한은 [확장앱 안내](plugins/README.md#disable-devtool-차단)를 참고하세요. 앱 v0.1.6부터 전체 사이트 권한을 지원하며 이후에는 확장앱만 업데이트합니다.
- Windows `Alt+Enter` 전체화면과 온라인 자막 검색·적용을 지원합니다. [변경 내역](CHANGELOG.md)과 [v0.1.6 배포 파일](https://github.com/gaeco0/OPlayer/releases/tag/v0.1.6)을 참고하세요. API 4를 지원하지 않는 v0.1.4 앱은 한 번 업데이트해야 합니다.

## 파일·재생목록 관리 (0.1.7-nightly.20261024.1)

- 로컬·원격 목록에서 오른쪽으로 끝까지 밀면 본 상태/안 본 상태가 전환됩니다. 펼쳐진 상태 버튼을 눌러도 됩니다. 안 본 상태로 바꾸면 이어보기 위치를 처음으로 되돌립니다. 왼쪽으로 밀면 기존 삭제 버튼이 나타납니다.
- 상단 **선택모드** 또는 파일 메뉴에서 파일을 선택하고 **선택 메뉴 → 재생목록에 추가 / 파일 삭제**를 사용합니다. 전체 선택은 현재 표시된 폴더의 파일에만 적용하며 하위 폴더를 재귀 선택하지 않습니다. 재생목록에는 영상·오디오만 추가합니다.
- 사이드바 **재생목록**에서 목록을 만들고 이름변경·삭제할 수 있습니다. 목록 안에서 끌어 순서를 바꾸고 원하는 항목부터 연속 재생합니다. 선택 메뉴로 항목을 목록에서 제거하거나 다른 목록/새 목록에 복사합니다. 같은 파일은 중복 추가하지 않습니다. 목록에서 제거해도 원본 파일은 유지합니다.
- 파일별 `⋮` 메뉴는 목록·격자에서 이름변경과 파일 삭제를 제공합니다. 이름변경은 로컬·WebDAV·FTP·SFTP·SMB에서 현재 폴더 내 파일에 적용하며 동명 항목을 확인하고 거부합니다. 폴더·심볼릭 링크의 이름변경은 제공하지 않습니다. 잠금·시청 기록·저장 재생목록의 참조는 새 파일명으로 옮깁니다. 자동 자막 매칭은 새 파일명 기준이며 자막 파일 이름은 바꾸지 않습니다.
- DLNA와 업로드를 선언하지 않은 클라우드 확장앱은 읽기 전용입니다. Google Drive 1.3.0은 업로드를 지원합니다. 리소스 확장앱이 `canDelete`/`canRename`을 선언한 경우에만 해당 작업을 제공합니다. 원격 재생목록은 계정·서버 식별자를 저장하고 재생 시 연결 정보를 다시 조회하므로 등록한 저장소와 확장앱이 필요합니다. NAS·FTP·SSH 실서버와 Android/TV의 직접 조작 검증은 별도로 필요합니다.

## OS 볼륨·클라우드 검색 (0.1.7-nightly.20261024.4)

- 재생 볼륨은 Android·iOS·Windows·Linux·macOS의 OS 출력 볼륨을 사용합니다. 재생 시작·종료 때 볼륨을 덮어쓰지 않으며 현재 OS 볼륨을 그대로 이어받습니다. 휠·방향키·볼륨 제스처는 OS 볼륨을 변경하고 하드웨어 키·시스템 슬라이더의 변경도 반영합니다. OS 볼륨 API 실패 시 변경 실패를 표시합니다.
- 클라우드/리소스 확장앱이 `canSearch: true`와 `search({query,path})`를 제공하면 저장소 상단에 검색 버튼이 나타납니다. 검색어·현재 폴더 ID를 확장앱에 전달하고 결과를 기존 파일 목록으로 표시합니다. 검색 닫기·뒤로가기는 원래 폴더 목록으로 돌아가며 검색 결과의 폴더를 열면 해당 폴더 탐색을 시작합니다.
- 검색 SDK와 예제는 [확장앱 개발 가이드](plugins/README.md#저장소-검색-api-4-선택-기능)를 참고하세요. SDK가 포함된 앱 업데이트 이후 공급자는 검색 훅을 JS로 배포하면 됩니다. 공식 Google Drive 1.3.0은 현재 폴더의 파일명 검색을 지원하며 기존 설치는 확장앱 업데이트가 필요합니다. 다른 확장앱에는 검색이 자동 추가되지 않습니다.

## Google 계정 동기화 (0.1.7-nightly.20261024.4)

- 설정 → **Google 동기화**에서 Google Drive 앱 전용 저장소에 재생목록·최근 재생·이어보기 위치를 동기화합니다. 별도 서버나 Google Drive 확장앱 설치가 필요하지 않으며 Apple·삼성 계정 연동은 제공하지 않습니다.
- 기기별 폴더·서버·클라우드 계정에 공통 동기화 이름을 지정해 파일을 연결합니다. 파일 내용·비밀번호·사이트 세션·잠금 정보는 전송하지 않습니다. 연결되지 않은 파일과 URL은 기기에만 남습니다.
- Android/Android TV와 Windows·Linux·macOS를 지원합니다. 운영자의 같은 Cloud 프로젝트 OAuth 등록값을 Actions Secret으로 빌드에 포함할 수 있으며 미등록 자체 빌드는 입력·등록 안내를 제공합니다. iOS는 별도 로그인 설정이 필요해 현재 지원하지 않습니다.
- 자동·수동 동기화, 오프라인 변경 보관, 삭제 병합을 지원하며 동일 재생목록의 동시 편집은 마지막 수정본을 사용합니다. 자세한 [설정·등록·동작 안내](docs/google-sync.md)를 참고하세요.

## 고화질 업스케일 (v0.1.6)

설정 → 재생 → **고화질 업스케일**, 플레이어 화면 비율 → **업스케일**에서 켜고 끕니다.
기본값은 꺼짐이며 선택은 저장됩니다. v0.1.6부터 포함됩니다.

낮은 해상도 영상을 화면보다 크게 표시할 때 mpv GPU의 Lanczos 필터로 영상·색상을 확대합니다.
화면의 실제 픽셀 수와 종횡비·회전·확대 비율을 반영해 출력 텍스처도 함께 확대하므로, 단순히 작은 텍스처를
Flutter에서 늘리는 방식과 다릅니다. 전체화면·작은 창·미니플레이어·PiP에 공통 적용합니다.
원본 크기 모드와 화면보다 큰 영상은 추가로 확대하지 않습니다. 설정을 끄면 원래 필터와 원본 출력 크기로 복원합니다.
오디오 전용 재생과 외부 캐스팅 수신기에는 적용하지 않습니다.

추가 출력은 한 변 최대 4096, 전체 최대 8,294,400픽셀로 제한하며 창 크기 변경은 묶어서 처리합니다.
GPU 부하·메모리 사용량이 늘 수 있으며 AI 모델 기반의 세부 묘사 복원 기능은 아닙니다.
실패한 설정·출력 크기는 원래 상태로 되돌리고 플레이어 패널에 오류를 표시합니다.
Android의 기존 출력 크기 API를 보완하기 위해 같은 media_kit_video 2.0.1의 소스를 로컬로 사용합니다.
추가 재생 엔진·모델은 없으며 패치 내역과 MIT 라이선스는 `packages/media_kit_video`에 보존합니다.

자동 검증: `flutter test test/video_upscaling_test.dart`. 실제 출력 검증은 보간 검증과 같은 작은 MP4를 준비한 뒤
`flutter run -d windows --debug -t tool/video_upscaling_smoke.dart`로 실행합니다.
Windows 실제 재생에서 160×90→640×360 GPU 출력과 Lanczos, 프레임 보간 동시 동작 및 해제 후 복원을 확인했습니다. Android·TV·Linux·macOS 실기기 화질·성능 확인은 별도 필요합니다.

## 가벼운 프레임 보간 (v0.1.6)

v0.1.6부터 **설정 → 재생 → 가벼운 프레임 보간**, 플레이어 **화면 비율 → 프레임 보간**을
지원합니다. 기본값은 꺼짐이며 선택은 앱 설정에 저장됩니다.

mpv의 `interpolation=yes`, `tscale=oversample`, `video-sync=display-resample`을 사용해 화면 주사율에
맞춰 인접 프레임을 혼합합니다. 실제 표시 중인 화면의 주사율을 사용하고 모니터 변경 시 갱신하며,
끄면 이전 시간축 필터·화면 주사율 재정의·영상 동기화 설정을 복원합니다. 영상 파일 자체의 FPS나
기존 색상·회전·반전 필터, 하드웨어 디코딩 설정은 변경하지 않습니다.

이 기능은 움직임을 추정하는 AI/모션 보간이 아닙니다. 영상 FPS와 주사율이 맞으면 엔진이 혼합을 생략할 수
있으며, 장면에 따라 흐림·잔상이 생길 수 있습니다. 오디오 전용 재생과 외부 캐스팅 장치에는 적용하지 않습니다.
지원하지 않는 옵션은 되돌리고, 재생 중 화면 동기화가 활성화되지 않으면 혼합을 해제해 상태를 표시합니다.
Windows 실제 영상 출력에서 활성화·해제·설정 복원을 확인했으며 Android·TV·Linux·macOS 실기기 확인은 남아 있습니다.

프레임 혼합 엔진 문서: [mpv interpolation](https://mpv.io/manual/stable/#options-interpolation).
개발 검증은 `flutter test test/frame_interpolation_test.dart`로 실행합니다. 실제 Windows 출력 검증:

```powershell
ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=24:duration=3" -c:v libx264 -pix_fmt yuv420p .dart_tool/interpolation.mp4
flutter run -d windows --debug -t tool/frame_interpolation_smoke.dart
```

테스트는 앱 설정을 바꾸지 않으며 보간 활성·화면 동기화·해제 후 원래 옵션 복원을 확인합니다.

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

- 현재 nightly: [v0.1.7-nightly.20261024.7](https://github.com/gaeco0/OPlayer/releases/tag/v0.1.7-nightly.20261024.7). Android 시스템 회전 호환 속성의 선언 범위 수정과 Google 계정 동기화·Drive 업로드·기본 OAuth 등록·OS 볼륨 연동·리소스 검색과 기존 다운로드 파일명 편집·덮어쓰기 확인을 포함한다. 기존 v0.1.6 이하 앱은 이 버전을 한 번 직접 설치해야 하며, 설치 후 업데이트 확인 기본 채널은 stable이다. 사용자가 직접 저장한 채널 선택은 유지한다. 정식 최신 버전은 v0.1.6을 유지한다.
- 일반 빌드의 기본 채널은 **nightly**이며, 같은 기본 버전에서 **nightly → beta → stable** 순서로 배포한다. 예: `0.1.7-nightly.20261023.1+2` → `0.1.7-beta.1+2` → `0.1.7+2`. nightly·beta는 GitHub 사전 릴리스이고 stable만 Latest로 등록한다. beta 게시 전에는 같은 기본 버전의 공개 nightly가, stable 게시 전에는 공개 beta가 있어야 한다. 승격은 사용자 지시 후 새 버전·릴리즈노트·태그를 준비하고 다시 빌드하는 방식이며 자동 승격하지 않는다.
- 각 단계의 태그는 `v0.1.7-nightly.20261023.1`, `v0.1.7-beta.1`, `v0.1.7` 형태다. Actions는 태그에서 채널을 확인하고 모든 플랫폼에 `--dart-define=OPLAYER_UPDATE_CHANNEL=채널`을 넣는다. 별도 지정 없이 로컬에서 빌드하면 nightly 채널이다. 내부 빌드 번호 `+2`와 기존 서명 키는 유지한다.
- 브랜치 push·PR·버전 번호 변경만으로는 빌드하지 않는다. 사용자가 배포를 지시할 때만 해당 커밋에 `v0.1.1` 같은 버전 태그를 만들고 push한다. `v*` 태그 push를 받으면 Windows, Android(mobile), Android TV(tv), Linux(x64), macOS(Apple Silicon 러너)를 빌드한다. Android·TV는 같은 배포 키로 각각 서명하며 Windows에서 정적 분석·Dart 테스트·브라우저 JavaScript 테스트도 실행한다.
- 다섯 빌드와 검증이 모두 성공하면 push된 태그에 GitHub Release와 배포 파일을 등록한다. 태그와 `pubspec.yaml` 버전이 다르면 게시를 거부한다. Actions는 태그를 생성하거나 이동하지 않는다. 기존 버전 교체도 사용자 지시가 있을 때만 해당 태그를 대상 커밋으로 갱신·push하며, 이 경우 같은 이름의 배포 파일을 교체한다.
- v0.1.1 이후 릴리스부터는 태그를 만들기 전에 `CHANGELOG.md`에 `## [버전]` 제목으로 추가 기능·수정 사항·알려진 제한을 정리한다. Actions는 해당 버전의 내용을 릴리스 본문 맨 위에 게시하며, 노트가 누락되면 게시를 거부한다. 일반 코드 push에서는 빌드하지 않는다.
- GitHub Release에 Android·Android TV의 ABI별 서명 APK 6개, Windows x64·ARM64 ZIP, Linux x64·ARM64 tar.gz, macOS Apple Silicon ZIP과 SHA256SUMS.txt를 첨부한다. 데스크톱 압축 파일은 실행 파일·라이브러리·데이터를 포함하므로 전체를 풀어 사용한다. 빌드 작업 간 전달용 Actions 아티팩트는 7일 동안 보관한다.
- nightly는 새 릴리스의 전체 파일 게시가 성공한 뒤 최신 3개만 남긴다. 태그 버전 순서로 오래된 nightly 릴리스·첨부 파일·태그를 삭제하며 stable·beta·초안·브랜치·커밋 이력은 보존한다. Actions 전달 아티팩트는 별도로 7일 보관한다.
- Windows·Linux의 x64와 ARM64(aarch64)를 별도 빌드한다. ARM 러너는 공식 Flutter 3.47.7 소스의 고정 커밋으로 네이티브 SDK를 준비한다. Windows ARM64에는 해당 아키텍처의 mpv·ANGLE·WebView2 로더를 사용하며, 게시 전에 각 DLL/SO와 실행 파일의 실제 아키텍처를 검사한다. [ARM64 의존성 소스·라이선스](third_party/angle-arm64/NOTICE.md)를 참고한다. Windows ARM64 ByeDPI는 기존 x64 보조 EXE를 OS 에뮬레이션으로 실행하므로 실기기 검증이 필요하다.
- 저장소 Actions Secrets에 `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`를 등록한다. 키와 비밀번호는 빌드 중 임시 복원 후 삭제하며, 저장소·릴리스에 커밋하거나 업로드하지 않는다.

### 앱 업데이트

- `.5`부터 Windows 창 닫기 경로로 종료하고 중복 설치·실행 검사와 실패 표시를 보완했다. 격리한 실제 Flutter Windows 앱에서 정상 종료·교체·새 프로그램 실행을 검증했다. 기존 `.3`·`.4`에는 앱 종료 오류가 남아 있으므로 이번 ZIP을 직접 받아 모든 OPlayer 창을 닫고 기존 실행 폴더에 내용을 덮어쓴다.
- v0.1.7-nightly.20261023.3에는 Windows 설치기 시작 지연·앱 종료 대기 오류 수정과 설치 단계·오류 로그 표시가 포함된다. 압축은 임시 캐시의 `updates/stage-*`에 풀어 검증하며, 최종 교체 대상은 현재 실행 중인 `oplayer.exe` 폴더다. 이전 nightly에서 설치 지연 오류가 나면 이번 ZIP을 직접 받아 앱 종료 후 실행 폴더에 덮어쓴다.
- 설정 → 앱 업데이트에서 자동 확인, stable·beta·nightly 채널 선택, 수동 확인·다운로드·설치를 제공한다. 업데이트 확인 기본값은 설치 빌드와 무관하게 stable이며, 사용자가 선택한 채널을 저장한다. 일반 빌드·배포 기본값인 nightly와 구분한다. 선택한 채널의 공개 릴리스만 확인하고 다른 채널의 새 버전은 섞지 않는다.
- 앱 시작·복귀 시 최대 6시간마다 GitHub 공식 저장소를 확인하고, 새 버전이 있으면 앱 안에 알림을 표시한다. 잠금 화면·백그라운드에서는 표시하지 않으며 잠금 해제 후 알린다. 자동 다운로드·자동 설치·백그라운드 주기 실행은 하지 않는다. 수동 확인은 확인 간격 제한 없이 가능하다.
- 설치 파일은 플랫폼·Android ABI·mobile/TV에 맞춰 선택하고, 크기와 SHA256SUMS.txt 및 GitHub가 제공하는 SHA256을 검증한다. 취소·전송 실패·변조 시 설치하지 않는다. 현재보다 새 버전만 알리며, 같은 기본 버전에서는 nightly → beta → stable을 승격 순서로 판단한다. Android는 OS가 허용하는 빌드만 설치한다.
- Android·Android TV는 패키지명·서명을 추가 검증한 뒤 OS 설치 확인 화면을 연다. 첫 설치에는 ‘이 출처 허용’이 필요할 수 있다. Windows는 사용자 확인 후 압축 파일을 준비하고 앱 종료를 기다려 실행 파일·라이브러리·데이터를 교체한 다음 재시작한다. 교체 실패 시 덮어쓴 파일을 복구한다. 진행 중인 재생·다운로드를 마친 뒤 설치한다.
- Linux·macOS는 검증된 압축 파일을 열고 사용자가 종료·압축 해제·교체한다. iOS 및 배포 파일이 없는 아키텍처는 인앱 설치를 지원하지 않는다. 확장앱 업데이트는 확장앱 저장소에서 별도로 관리한다.
- 기본 `main`의 `LICENSE`는 `devel`과 `main`에서 그대로 유지한다. `third_party/`의 외부 구성요소는 각 디렉터리의 라이선스도 함께 적용된다.

## 기능

- 다음 배포: 설정 → 정보 → **진단 정보 보내기**에서 제목·증상·재현 방법을 작성하고 진단 미리보기·첨부 여부를 선택해 [OPlayer GitHub Issues](https://github.com/gaeco0/OPlayer/issues)에 접수한다. 플레이어의 회전 버튼 길게 누르기 → GitHub 이슈 보내기에서도 접근한다. 외부 GitHub 작성 화면에서 사용자가 로그인·검토·최종 등록한다. 긴 본문은 클립보드로 전달하며 파일명·경로·URL·헤더·계정·토큰은 자동 진단에 포함하지 않는다.
- 다음 배포: 각 로컬/등록 폴더/원격 리소스에서 마지막으로 실제 재생한 파일명과 해당 파일로 이어지는 탐색 경로를 **파란색**으로 표시한다. 목록·격자·현재 경로에 적용하며 다른 리소스를 재생해도 해당 리소스의 표시는 유지한다. 이후 재생부터 기록하고 본 상태 전환과 구분한다. 표시용 파일·부모 폴더 ID는 기기에만 저장하며 Google 동기화와 진단에는 포함하지 않는다.

| 영역 | 내용 |
|---|---|
| 로컬 | 폴더 탐색, 폴더 추가, 정렬(이름·날짜·크기, 자연 정렬), 목록/격자, **썸네일 캐시**, 이어보기 진행바 |
| 네트워크 | **SMB**(Dart SMB 클라이언트 → 로컬 HTTP Range 프록시), **FTP/FTPS**(ftp:// 직접), **SFTP**(비밀번호/개인 키, 호스트 키 고정 → 프록시), **WebDAV**(http(s)+Basic 인증), **UPnP/DLNA** 자동 검색 |
| 클라우드 | **Google Drive / Dropbox / OneDrive / S3 호환 / Box / 네이버 MYBOX** 확장앱 — 자체 설정, 계정 연결, 폴더 탐색, 스트리밍 재생 |
| 웹 | 내장 브라우저(북마크), 페이지 내 동영상 자동 감지(video 태그·fetch/XHR·리소스 로드), 바로 재생 / 다운로드 |
| 다운로드 | mp4·webm 등 직접 파일 이어받기, **HLS(m3u8)** 최고 화질 선택·병렬 조각 받기·AES-128 복호화·병합(.ts / fMP4는 .mp4), 일시정지/재개 |
| 플레이어 | 제스처(탐색·밝기·볼륨·핀치·더블탭·길게 눌러 2배속), 잠금, 화면비, 배속, A-B 반복, 자막 트랙/싱크/크기, 오디오 트랙, 재생목록, 단축키 |
| 공통 | 최근 재생(로컬·원격 모두 다시 열기), 설정 화면, 비밀번호/토큰은 OS 보안 저장소 |

DRM(Widevine/FairPlay, SAMPLE-AES)으로 보호된 스트림은 재생·다운로드 대상이 아니다.

### 추가된 재생·탐색 기능

- 로컬·원격 목록/격자에서 왼쪽으로 밀어 ‘삭제’를 누르면 실제 파일·폴더를 삭제한다. 폴더는 하위 항목도 함께 삭제하며 휴지통 이동·되돌리기는 제공하지 않는다. WebDAV·FTP·SFTP·SMB는 서버 쓰기 권한이 필요하고, 등록한 루트·SMB 공유 자체는 삭제 대상에서 제외한다. 삭제 중에는 진행 표시·중복 클릭 방지를 제공하고 성공·실패 후 목록을 다시 조회한다. 폴더 안의 별도 잠금 항목도 인증해야 한다. DLNA와 삭제 미지원 클라우드 확장앱에는 삭제 버튼을 제공하지 않으며, Drive 업로드 권한과 파일 삭제 지원은 별도로 취급한다([개발 규약](plugins/README.md)).
- 모바일 설정 → 재생 → ‘플레이어 화면 회전’에서 가로 고정·세로 고정·자동 회전을 선택한다. 재생 화면의 기존 회전 버튼도 같은 설정을 순환하고 선택을 저장한다. Android 자동 회전은 OS 세로 잠금과 관계없이 센서를 사용하고, 플레이어를 닫으면 시스템 회전 정책으로 복원한다. 데스크톱·Android TV에는 제공하지 않는다([Android 센서 회전](https://developer.android.com/guide/topics/manifest/activity-element#screen)).
- Android 모바일의 가로·세로 고정은 네이티브 화면 방향 요청을 사용한다. API 36 큰 화면 제한 제외 속성은 Activity에, 제조사 회전 호환 정책 제외 속성은 Application에 선언한다. `.6`에서 도입한 플레이어 자체 회전은 OS 방향을 바꾸지 못해 `0.1.7-nightly.20261024.7`에서 제거했다. 시스템이 요청을 무시하더라도 플레이어 내부만 별도로 회전시키지 않는다. 자동 회전·TV 정책은 유지하며 Fold6 실기기 검증은 남아 있다. API 37부터 큰 화면 제한 제외가 지원되지 않으므로 대상 SDK를 올릴 때 별도 대응이 필요하다([Android 속성 규격](https://developer.android.com/reference/android/view/WindowManager#PROPERTY_COMPAT_ALLOW_ORIENTATION_OVERRIDE), [큰 화면 안내](https://developer.android.com/guide/practices/device-compatibility-mode)).
- 다음 배포부터 Android 플레이어의 회전 버튼을 길게 누르면 `화면 회전 진단`을 표시하고 복사할 수 있다. 가로 고정을 선택한 뒤 접힌 상태와 펼친 상태에서 각각 복사하면 앱 요청 방향·OS 적용 방향·창 크기·최소 폭·설치된 속성 범위·SDK·멀티윈도/PiP 차이를 비교할 수 있다. 진단 정보는 자동 전송하지 않으며 회전 문제 해결 여부는 실기기에서 확인해야 한다.
- 로컬·네트워크·클라우드 폴더는 경로별로 정렬 기준(이름·날짜·크기), 오름차순/내림차순, ‘폴더 먼저 표시’를 기억한다. 정렬 메뉴에서 변경하면 즉시 저장되어 폴더 재방문과 앱 재시작 후에도 복원되며, 서버와 하위 폴더별로 독립 적용된다.
- 앱 복귀 후 현재 폴더 목록은 자동 재조회한다. 앱 잠금이 있으면 해제를 기다리고, 리소스 잠금은 재조회 전에 별도로 인증한다. 네트워크 목록은 캐시를 건너뛰며, 잠긴 리소스를 수동 해제한 뒤에도 목록을 다시 불러온다. 다른 화면 뒤에 가려진 폴더는 해당 화면으로 돌아올 때 갱신한다.
- 폴더 안에서도 뒤로가기와 메뉴 버튼을 함께 제공하며 서버 연결 중에도 메뉴를 열 수 있다.
- Windows·macOS·Linux에서 파일을 끌어다 놓아 영상·오디오를 재생하거나 사진을 연다. Windows는 탐색 중에도 재생하는 앱 내 미니플레이어와 항상 위에 표시되는 작은 창 모드를 제공한다. Android의 최소화는 백그라운드 재생으로 처리한다.
- Windows 플레이어는 `Alt+Enter` 또는 오른쪽 위 전체화면 버튼으로 창 테두리 없이 현재 모니터 전체를 사용한다. 다시 전환하면 기존 위치·크기·최대화 상태를 복원하며 작은 창 모드와 함께 켜지지 않는다. `Esc`는 열린 패널을 먼저 닫고, 패널이 없으면 전체화면을 해제한다. 플레이어 종료·앱 내 최소화 시에도 원래 창으로 돌아온다.
- Android 8 이상 PiP: 플레이어 버튼 또는 재생 중 홈으로 이동. 작은 창에는 `뒤로 · 재생/일시정지 · 앞으로` 세 버튼만 표시하며 탐색 숫자·간격은 더블탭 탐색 설정을 따른다.
- Android 미디어 알림과 잠금 화면에서는 10초 탐색·재생/일시정지·이전/다음 파일 조작을 제공한다. 헤드셋 버튼과 조작 묶음 전환은 사용하지 않는다. 오디오 전용 파일은 앨범 표지 유무와 관계없이 홈 이동 후에도 재생하고, 영상은 PiP 또는 백그라운드 설정을 따른다. 이어폰 분리 시에는 일시정지한다.
- Android 다운로드는 진행 알림이 있는 dataSync 포그라운드 서비스와 CPU 절전 방지 잠금으로 홈 이동·화면 꺼짐 중 작업을 유지한다. Android 13 이상은 첫 다운로드 때 알림 권한을 요청한다. 알림에서 다운로드 목록 열기·전체 일시정지를 지원하고 완료·실패도 표시한다. 앱 강제 종료·최근 앱에서 작업 제거 시에는 계속 실행하지 않으며, Android의 서비스 시간 제한 시 안전하게 일시정지한다. 실제 기기와 제조사별 절전 정책 검증은 별도로 필요하다.
- Android에는 FFmpeg를 내장하여 HLS 수신 후 MP4로 스트림 복사하고 분리된 영상·음성을 병합한다. 별도 설치는 필요 없다. Windows/macOS/Linux는 설정에서 외부 FFmpeg를 자동 탐색하거나 지정한다.
- Chromecast(Android)·DLNA 외부 출력: 같은 네트워크 기기 검색, 탐색·재생/일시정지·볼륨·종료. 로컬 파일과 HTTP 기반 네트워크 소스를 Range 지원 릴레이로 전달한다. FTP 직접 출력은 지원하지 않으며 먼저 로컬 파일로 받아야 한다.
- 오디오 싱크·증폭·10밴드 EQ, 영상 회전·반전·색상 조정, 자막 파일 선택·위치·크기·싱크, 종료 타이머·화면 캡처. 효과 적용 여부는 재생 엔진에 따라 달라진다.
- 브라우저 휠 이동량 40% 적용(파일 목록 휠은 유지), Android/iOS 브라우저와 로컬·네트워크 파일 목록에서 당겨서 새로고침.
- 브라우저의 뒤로·앞으로 URL 기록과 현재 위치를 기기에 저장합니다(최근 500개). 메뉴 이동·앱 재시작 후 브라우저를 열면 현재 페이지만 새로 요청하고, 이전·다음 기록은 탐색할 때 불러옵니다. 돌아간 위치에서 새 페이지를 열면 앞으로 기록을 지웁니다. 홈페이지 버튼은 설정한 홈페이지로 이동합니다. 페이지의 입력·스크롤·JavaScript 실행 상태와 POST 본문은 복원하지 않습니다.
- Android·Windows 설정 → 앱 네트워크: DoH와 ByeDPI 각각 켜기/끄기, HTTPS DoH 쿼리 URL 지정·저장. 내장 브라우저와 HTTP(S) 다운로드·재생에 적용하며, NAS 등 내부 주소와 FTP/SMB/SFTP·외부 출력 기기 자체 통신에는 적용하지 않는다. 설정을 바꾸면 웹페이지를 새로고침하고 영상을 다시 연다.
- DoH는 RFC 8484 `application/dns-message` POST를 사용한다. DoH 서버의 최초 주소 조회에는 시스템 DNS를 사용하고, 조회 실패 시 일반 DNS로 재시도하지 않는다. ByeDPI v0.17.3 엔진은 앱이 실행·종료를 관리하며 TLS 인증서 검증은 그대로 유지한다. Android는 프록시 설정을 지원하는 System WebView가 필요하다.
- ‘등록한 리소스에도 DoH·ByeDPI 적용’은 기본 OFF이며 DoH 또는 ByeDPI가 켜져야 선택할 수 있다. 둘 다 끄면 리소스 적용도 자동 OFF·비활성화되고, 다시 켜도 리소스 적용은 사용자가 직접 선택한다. 기존 설정에 명시적으로 저장된 ON은 둘 중 하나가 켜져 있을 때 유지한다.
- HLS 요청 헤더 재사용, 브라우저에서 받은 재생목록 보존, identity AES-128 키 교체 구간을 페이지의 기존 키 로더로 미리 준비. 사이트 전용 JSON의 암호화된 필드를 원시 AES 키로 사용하지 않는다.

Chromecast·DLNA·PiP는 실제 Android/TV 기기 검증이 필요하다. nPlayer의 모든 기능과 일치하는 구현은 아니며 AirPlay 송신·NFS는 포함하지 않는다.

### 다운로드 파일명 (0.1.7-nightly.20261024.2)

- 브라우저 영상과 원격 리소스 파일 모두 다운로드 전에 **저장 파일명** 입력창을 엽니다. 인식한 파일명이 미리 채워지며 수정하거나 취소할 수 있습니다. 브라우저는 출력 화질 선택 후 파일명을 입력하며 확장자는 실제 저장 형식에 맞춥니다.
- 같은 파일이 있으면 **덮어쓰기 / 다른 이름으로 저장 / 취소**를 선택합니다. 로컬 파일은 다운로드·변환을 마친 뒤 교체하므로 그 전에 실패하면 기존 파일을 보존합니다. 같은 이름의 폴더나 진행 중인 다운로드가 있으면 다른 이름을 입력합니다.
- 설정한 원격 업로드 위치도 동명 파일을 검사합니다. 덮어쓰기 동의는 확인한 대상에만 적용하며 목적지·출력 확장자가 바뀌거나 새 충돌이 생기면 번호를 붙여 구분합니다. 원격 업로드 중 기존 파일 보존 여부는 해당 저장소의 업로드 방식에 따릅니다.

### 원격 저장소 파일 다운로드

- 등록한 SMB·FTP/FTPS·SFTP·WebDAV·클라우드 저장소에서 파일의 `⋮` 메뉴 또는 길게 누르기 → **기기에 다운로드**를 선택한다. 격자는 다운로드 버튼도 제공한다. 일반 파일은 정렬 메뉴의 **미디어만 표시**를 끄면 다운로드 버튼이 나타난다.
- 설정의 로컬 다운로드 폴더에 원본 파일을 저장하고 기존 다운로드 목록에서 진행률·속도 확인, 일시정지·재개·취소가 가능하다. Android에서는 기존 포그라운드 다운로드 알림을 사용한다. 브라우저용 MP4 화질 변환·원격 업로드 위치는 적용하지 않는다. 0.1.7-nightly.20261024.2부터 저장 파일명을 수정하고 동명 파일 덮어쓰기 여부를 선택할 수 있다. 확인하지 않은 새 충돌은 번호를 붙여 구분한다.
- 저장소·파일과 다운로드 목록·저장 폴더의 잠금을 확인한다. 재개 시 저장소 설정에서 인증과 임시 링크를 다시 얻으므로 클라우드 확장앱을 새로 설치할 필요는 없다. 등록한 서버·계정을 삭제하거나 확장앱을 끄면 다시 받기에 실패할 수 있다.
- 이어받기는 HTTP Range 또는 FTP REST 지원 시 사용하고, 서버가 지원하지 않으면 처음부터 받는다. 잘못된 범위·불완전 전송은 완료 처리하지 않는다. 파일 단위 다운로드이며 폴더 전체 받기는 지원하지 않는다. DLNA는 앱 재시작 후 서버 목록에서 새로 추가해야 한다.
- 로컬 HTTP·FTP 서버에서 전송·중단·인증 갱신·이름 충돌을 검증했다. 실제 NAS·클라우드 계정·Android 장시간 동작은 추가 확인이 필요하다. v0.1.6부터 제공한다.

### 브라우저 재생·다운로드

- WebDAV를 다운로드 저장 위치로 사용할 때, 업로드 중 Broken pipe·연결 초기화 또는 완료 응답 유실은 새 연결로 최대 3회 다시 시도한다. 재시도 전 2·4초 대기하며 매번 파일 전체를 보내고 진행률·속도를 초기화한다. `Connection: close`를 강제하지 않는다. 서버의 성공 응답을 확인해야 완료 처리하고 로컬 원본을 삭제한다. 반복 실패 시 각 시도의 경과 시간·전송 스트림 전달량을 표시하고 원본을 보관하므로 다운로드 목록에서 재개하면 업로드를 다시 시도한다. 표시한 전달량은 서버 저장량과 다를 수 있다. 명확한 HTTP 거절 응답·전송 정지 감시의 타임아웃·사용자 일시정지는 자동 재시도하지 않는다. 이 연결 복구는 v0.1.6부터 제공한다.
- 다른 대상에 저장하려면 다운로드 항목의 `⋮` → **다른 저장소로 이동**을 선택한다. 기기에 받은 파일이 남아 있는 실패·일시정지·완료 항목에서 기기 다운로드 폴더·직접 고른 로컬 폴더·등록한 SMB/FTP/FTPS/SFTP/WebDAV 서버와 폴더를 선택한다. 업로드가 진행 중이면 먼저 일시정지한다. 보관 파일을 사용하므로 원본을 다시 다운로드하지 않으며, 이 항목의 목적지만 변경한다. 저장소·파일 잠금을 확인하고 새 대상의 저장 완료 후 기존 파일을 지운다. 실패·취소하면 원본을 보존하고 이름 충돌은 번호를 붙여 구분한다. 이미 원격 업로드를 완료해 기기에 원본이 없는 항목과 아직 파일을 전부 받지 못한 항목은 제외한다. 이 옵션은 v0.1.6부터 제공한다.

다른 앱에서 파일 열기:

- Android·Android TV: 파일 탐색기에서 영상·오디오·사진의 **연결 프로그램/다른 앱으로 열기 → OPlayer**를 선택한다. 앱이 실행 중이어도 새 파일을 받으며, 앱 잠금 중에는 해제 후 연다. 영상·오디오는 제공받은 `content://` 읽기 권한으로 직접 재생한다. 사진만 임시 캐시로 읽으며 이 경로는 최대 64 MiB를 지원한다. 임시 접근 권한만 제공하는 파일 탐색기는 나중에 최근 재생에서 다시 열 때 파일을 다시 선택해야 할 수 있다.
- Windows: 앱을 한 번 실행한 뒤 파일의 **연결 프로그램 → OPlayer** 또는 Windows 기본 앱 설정에서 선택한다. 사진도 등록하며 기존 기본 앱은 유지한다.
- macOS·iOS: 설치한 앱을 Finder의 **다음으로 열기** 또는 파일 앱의 **다른 앱에서 열기**에서 선택한다. OS가 제공하는 문서 접근 권한을 사용한다.
- Linux: 압축을 푼 앱을 한 번 실행하면 `~/.local/share/applications`(또는 `XDG_DATA_HOME`)에 연결 항목을 등록한다. 이후 파일 관리자의 **다른 프로그램으로 열기 → OPlayer**에서 선택한다. 앱 폴더를 이동했다면 이동한 위치에서 다시 실행해 경로를 갱신한다. 데스크톱 캐시 갱신에는 선택적으로 `desktop-file-utils`를 사용한다.

위 파일 연결 보완은 v0.1.6부터 제공한다.

- 브라우저에서 감지한 HLS·일반 영상의 내장 플레이어 재생도 브라우저 다운로드와 같은 세션·요청 헤더를 사용한다. 로컬 재생 연결을 통해 HLS 재생목록/오디오/초기화 조각/키 URI를 변환하고, 관찰된 identity AES-128 키를 메모리에서만 전달한다. 네이티브 HTTP 401/403 시 다운로드에 사용하는 브라우저 전송으로 재요청하며 일반 영상의 Range 요청도 전달한다.
- 재생 종료·항목 전환 시 로컬 연결과 해당 세션의 키 복사본을 정리한다. 최근 웹 영상의 브라우저 요청 정보는 실행 중 메모리에서만 제한적으로 유지하며, 앱 재시작 후 인증·만료된 웹 영상은 페이지를 다시 열어야 한다. DRM은 지원하지 않는다.
- 브라우저 재생 준비·수신 실패는 플레이어에 표시하고 시작 시 60초 동안 데이터가 없으면 오류로 종료한다. `tool/browser_playback_smoke.dart`는 사용자 저장 정보를 읽지 않고 로컬 생성 암호화 영상의 403 재요청과 실제 재생 엔진 복호화를 검증한다.

## 온라인 자막 확장앱

- OpenSubtitles 다운로드에서 ‘허용되지 않은 자막 다운로드 도메인’이 나오면 설정 → 확장앱에서 목록을 새로고침하고 공식 저장소의 OpenSubtitles를 **1.0.4로 교체**한다. `*.opensubtitles.org`·`*.opensubtitles.com` 다운로드와 HTTP 링크의 HTTPS 전환을 지원하며, 앱 재설치는 필요 없다.
- 플레이어 자막 메뉴 → **온라인 자막 검색·적용**에서 영상 제목을 자동 입력하고 한국어(`ko`)를 기본으로 검색한다. 제목·언어·공급자를 바꿀 수 있고, 결과 선택 또는 ‘검색 후 첫 결과 적용’으로 내려받아 현재 영상에 적용한다.
- **OpenSubtitles**는 공식 저장소에서 선택 설치한다. 설정 → 확장앱 → OpenSubtitles 설정에서 API Key를 입력한다. 사용자 이름·비밀번호는 선택 사항이며, 비워 두면 로그인 없이 검색·다운로드한다. 계정을 입력하면 해당 계정으로 다운로드하며 서비스의 할당량을 따른다. User-Agent·기본 언어도 확장앱에서 설정한다. 연결 정보는 공통 보안 저장소에 보관한다. API Key 발급·사용 조건은 [공식 안내](https://opensubtitles.tawk.help/article/getting-started)를 따른다.
- OpenSubtitles 확장앱에서 **재생 시작 시 자동 검색·적용**을 켜면 사용할 내장·외부 자막이 없는 영상에 첫 검색 결과를 자동 적용한다. 기본은 OFF이며 자동 검색은 영상 제목을 공급자에게 전송한다. 다운로드 할당량은 서비스 정책을 따른다. 잘못 맞는 결과는 자막 메뉴에서 다른 결과를 선택하거나 싱크를 조정한다.
- 자막 파일은 임시 폴더에 보관하고 재생 항목 변경·종료 시 정리한다. 영상 전환·창 닫기·수동 자막 선택으로 취소된 요청은 뒤늦게 적용하지 않는다. 검색·다운로드 실패는 영상 재생을 중단하지 않는다.
- 다른 자막 사이트는 `kind: "subtitle"`, `api: 4` 확장앱으로 추가한다. 공급자의 검색·로그인·다운로드 URL 처리와 설정은 JS가 정의하며 앱은 공통 규약으로 결과와 파일을 처리한다. [개발 문서](plugins/README.md#자막-검색-api-4)를 참고한다.

## 클라우드 설정 (필수)

설정 → 확장앱 → 해당 확장앱의 설정(톱니바퀴)에서 앱 등록·접속 정보를 입력한다. 첫 연결 시에도 해당 확장앱의 등록 안내가 열린다. 처음 시작할 때 설치된 확장앱은 없으며 Google Drive·Dropbox·OneDrive·S3 호환 스토리지·Box·네이버 MYBOX 모두 공식 저장소에서 선택 설치한다. 확장앱별 설정·검증·인증 흐름은 JS가 정의하며 비밀값은 기기 보안 저장소에 보관한다. 확장앱을 꺼도 연결 정보는 보관한다. 아래 등록 정보와 [확장앱별 안내](plugins/README.md)를 참고한다.

- OneDrive: Microsoft Entra 앱 등록에서 개인 Microsoft 계정을 포함하는 계정 유형과 모바일 및 데스크톱 플랫폼을 선택한다. 권한은 Files.Read, User.Read, offline_access. 커스텀 복귀 주소 `com.oplayer.oplayer://oauth/onedrive`와 데스크톱 `http://localhost:53682/callback`을 등록한다.
- Dropbox: Scoped access / Full Dropbox 앱을 만들고 files.metadata.read, files.content.read, account_info.read 권한을 켠다. `com.oplayer.oplayer://oauth/dropbox`와 `http://localhost:53682/callback`을 등록한다.
- Google Drive: Google Cloud 프로젝트에서 Drive API를 사용 설정하고 OAuth 동의 화면에 `https://www.googleapis.com/auth/drive`와 테스트 사용자를 추가한다. 공식 Drive 확장앱 1.3.0은 전체 탐색·읽기·업로드를 지원하며 기존 읽기 전용 계정은 다시 연결해야 한다. 다운로드 저장 위치 또는 다른 저장소로 이동에서 Drive 폴더를 선택할 수 있다. Windows/macOS/Linux에서는 **데스크톱 앱** 유형의 Client ID와 Client Secret을 설정에 입력한다. 직접 입력한 Secret은 기기의 보안 저장소에 Client ID별로 보관한다. 운영자 등록값의 Actions 주입은 [Google 등록 안내](docs/google-sync.md)를 따른다. 데스크톱 배포본에 포함한 Secret은 바이너리에서 추출 가능하므로 서버 비밀로 사용하지 않는다. 로그인은 시스템 브라우저와 `http://127.0.0.1:53682/callback` 루프백, PKCE로 처리한다.
- Google Drive Android/Android TV: **Android** 유형의 OAuth 클라이언트를 만든다. 앱 등록 화면에 표시되는 현재 패키지와 서명 SHA-1을 그대로 등록하고 Client ID를 입력한다. 모바일 `com.oplayer.oplayer`와 TV `com.oplayer.oplayer.tv`, 디버그/배포 서명은 각각 등록한다. Google Play 서비스의 공식 Authorization SDK를 사용하며 Android 루프백·커스텀 스킴은 사용하지 않는다. TV도 Google Play 서비스 및 계정·동의 UI가 필요하다. iOS의 Google Drive 연결은 지원하지 않는다.
- `drive`는 제한된 범위이므로 공개 배포 로그인에는 Google OAuth 검증이 필요하다. 외부 테스트 모드에서는 등록한 테스트 사용자만 접속할 수 있고 갱신 토큰이 7일 후 만료될 수 있다. [Google OAuth 안내](https://developers.google.com/identity/protocols/oauth2/native-app), [Android 인증 안내](https://developer.android.com/identity/authorization), [Drive 권한 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).
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

Android는 시스템 인증서와 사용자가 기기에 설치한 CA 인증서를 신뢰한다. AdGuard HTTPS 필터링을 사용하려면 AdGuard CA가 기기의 사용자 인증서 저장소에 설치되어 있어야 한다. WebView·Android 네트워크 API뿐 아니라 Dart의 확장앱 저장소·클라우드·다운로드 요청도 Android의 신뢰 저장소를 사용하고 앱 복귀 시 CA 변경을 확인한다. 호스트명·유효기간·인증서 체인 검증은 유지한다. 내장 브라우저의 감지된 동영상 → 요청 기록에서 리소스 로드 실패·HTTP 오류를 확인할 수 있다.

## 구조

```
lib/
  main.dart
  app/theme.dart
  core/
    media_item.dart        재생 항목(URI·헤더·자막·지연 resolve)
    settings.dart          앱 설정 (SharedPreferences)
    plugins/               확장앱 저장소·공통 설정/인증·HTTP·암호·HTML/XML/JSON 파서
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
| Alt+Enter (Windows) | 전체화면 전환 (Esc로 해제) |

## 남은 작업

### 미구현 기능

- Linux 플레이어의 창 전체화면 전환 조작. Windows 전체화면·작은 창·앱 내 미니플레이어는 구현되어 있으며, macOS는 기본 창 전체화면 메뉴를 제공한다.
- Plex·Jellyfin 전용 API 로그인·라이브러리 연동. 해당 서버가 제공하는 UPnP/DLNA 탐색과는 별개다.
- Google Drive의 공유 드라이브 목록·선택 화면. 현재 공식 확장앱은 ‘내 드라이브’에서 시작하며, 공유 드라이브 호환 요청 옵션만으로 별도 목록을 제공하지는 않는다.

### 추가 검증

- Android·TV 실기기의 업데이트 출처 허용·설치 확인, 실제 구버전에서 새 버전으로의 업데이트와 채널 변경, Windows 실제 배포 폴더의 재시작·권한·잠긴 파일 처리. Windows 설치기 임시 폴더 검증·복구와 API·체크섬 모의 테스트는 실제 배포 검증과 구분한다.
- Android·Android TV 실기기의 PiP·백그라운드 재생·미디어 알림, 장시간 다운로드와 제조사 절전 정책, TV 리모컨 조작.
- SMB 대용량 폴더 탐색·삭제 성능, Windows WebView 미디어 감지 범위, Android AdGuard HTTPS 필터링 환경의 사이트별 동작.
- 실제 클라우드 계정·서버를 사용한 로그인·목록 탐색·재생·토큰 갱신과 서비스별 권한 설정. 모의 OAuth/API 테스트와 실서비스 검증을 구분한다.
- Linux·macOS 실환경의 재생·네트워크 연결·확장앱 동작, Android 지문·Windows Hello 인증 및 캡처 방지. v0.1.4의 5개 플랫폼 CI 빌드 성공이 모든 실기기 동작 검증을 뜻하지는 않는다.
- iOS 빌드·기기 검증과 배포 절차. 현재 GitHub Actions의 배포 대상은 Windows·Android·Android TV·Linux·macOS다.
