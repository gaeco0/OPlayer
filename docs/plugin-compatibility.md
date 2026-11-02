# 확장앱 OS 호환성 점검

2026-11-03 기준, 공식 저장소 13개 확장앱을 검토했습니다.

| 기능 | Android / TV | Windows | Linux | macOS |
| --- | --- | --- | --- | --- |
| 클라우드·PeerTube·Jellyfin·S3 | 지원 | 지원 | 지원 | 지원 |
| 자막 검색·영상 필터·업스케일 모델 | 지원 | 지원 | 지원 | 지원 |
| RIFE 모델 공급 | 지원 | 지원 | 지원 | 지원 |
| 브라우저 disable-devtool 차단 | 지원 | 지원 | 미지원: 내장 WebView 없음 | 지원 |
| Google 파일 선택 | 네이티브 SDK | OAuth 시스템 브라우저 | OAuth 시스템 브라우저 | OAuth 시스템 브라우저 |

이는 코드·빌드·테스트로 확인하는 지원 범위입니다. Android TV는 Android SDK 경로를 공유합니다.
iOS는 현재 배포 대상이 아니며 공식 확장앱의 지원 플랫폼으로 표시하지 않습니다.

## 방지 장치

- `platforms`를 설정 화면뿐 아니라 설치·활성화·목록·직접 실행에도 적용합니다.
- 저장소 JSON과 JS의 플랫폼·필수 호스트 기능·API 버전이 일치해야 설치됩니다.
- 신규 호스트 기능에 의존하면 API 5와 `requiresHost`를 명시합니다. 알 수 없는 기능은 거절합니다.
- Google Drive 1.5.0은 `requiresHost: ["googlePicker"]`를 요구해 구형 앱에 설치되지 않습니다.
- Android Google Picker 다중 선택·MIME·파일 ID·폴더 옵션을 SDK로 전달합니다. 미지원 옵션은 조용히 무시하지 않고 거절합니다.
- 백그라운드 갱신은 Picker를 열지 않으며 계정이 바뀐 토큰을 기존 리소스에 저장하지 않습니다.
- 공식 확장앱 메타데이터를 5개 OS(iOS의 미지원 판정 포함)에서 검사하는 회귀 테스트를 유지합니다.
- 릴리즈 CI에서 Windows x64 전체 테스트에 더해 Windows ARM64·Linux x64/ARM64·macOS의 네이티브 JS 등록 및 HTML/XML/JSON 스모크 테스트를 실행합니다.
- Android·TV는 실제 네이티브 SDK 컴파일과 Dart 채널 옵션 테스트를 수행합니다.

## 수동 확인이 필요한 부분

Google 계정 로그인·Picker 화면, 외부 클라우드의 실제 계정 권한, TV 리모컨 조작 및 기기 GPU/NPU 상태는
모의 테스트나 컴파일만으로 검증할 수 없습니다. 모든 OS의 실제 기기를 직접 조작한 결과로 간주하지 않습니다.
Google Cloud에서 Google Picker API 활성화가 필요하며, `drive.file`은 선택한 파일·앱 생성 파일만 허용합니다.
폴더 선택은 하위 파일 전체에 대한 재귀 권한을 의미하지 않습니다.
