# OPlayer Google 권한 심사 동영상 촬영 시나리오

OPlayer가 Google 권한으로 제공하는 Drive 탐색·재생, 파일 업로드·덮어쓰기, 재생 기록 동기화를 실제 화면으로 보여준다. 촬영자는 아래 순서대로 조작하고, 영문 자막은 각 장면에 붙인다. 웹캠과 마이크는 필요 없다.

기준 앱은 **0.1.9-nightly.20261103.3**, 파일 탐색 확장앱은 **Google Drive 1.6.0**, 동기화 확장앱은 **Google Drive 동기화 1.0.0**이다. 권장 길이는 7~9분이며 실제 로그인·전송 시간에 따라 조정한다. 이는 촬영 구성상 목표 시간이다.

## 촬영 전에 맞출 항목

1. Google Cloud에 제출한 범위와 두 확장앱의 실제 요청 범위를 아래 표와 대조한다. 이 촬영안은 세 범위를 제출하는 구성을 기준으로 하며, 예전 전체 `https://www.googleapis.com/auth/drive` 범위는 포함하지 않는다.
2. **개인정보처리방침 정합성을 먼저 확인한다.** 현재 저장소의 `docs/privacy.html`에는 예전 전체 `drive` 권한 안내가 남아 있다. 등록한 실제 정책 URL에도 같은 안내가 노출되면 현재 `drive.readonly + drive.file` 및 별도 `drive.appdata` 동작으로 현행화한 뒤 촬영한다. 홈페이지·정책의 제출 URL은 Cloud Console에 실제 등록한 주소와 일치시킨다.
3. Windows와 Android의 OAuth 클라이언트가 같은 Google Cloud 프로젝트에 속하는지 확인한다. 다른 프로젝트의 앱 전용 데이터는 서로 공유되지 않는다.
4. 심사용 Google 계정을 준비한다. 실제 동의 화면이 나오도록 새 테스트 계정 또는 해당 테스트 계정의 기존 연결 상태를 준비한다. 로그인·추가 인증·권한 승인은 계정 소유자가 직접 진행한다.
5. 앱 이름과 로고가 보이게 녹화하고 Google 동의 화면 언어를 **English**로 설정한다. 권한 설명이 접혀 있으면 펼쳐 읽을 수 있게 보여준다. 비밀번호·Client Secret·토큰은 녹화하지 않는다.
6. Windows A와 별도 기기 Android B에 앱과 두 확장앱을 설치·활성화한다. B는 새 설치 또는 동기화 자료가 없는 테스트 환경으로 준비한다. 두 기기에서 같은 Google 계정을 사용한다.

Google은 실제 앱의 전체 OAuth 과정, 모든 요청 권한과 그 기능 사용을 보여주도록 안내한다. 여러 OAuth 흐름이 있다면 각각 담고, 영문 동의 화면과 설명 자막을 사용한다. [Google 동영상 안내](https://support.google.com/cloud/answer/13804565?hl=en)

## 권한과 촬영 증빙

| 요청 주체 | 범위 | 영상에서 보여줄 내용 |
| --- | --- | --- |
| Google Drive 확장앱 | `https://www.googleapis.com/auth/drive.readonly` | 앱 밖에서 미리 넣은 파일·하위 폴더를 탐색하고, 영상 내용을 스트리밍 재생한다. |
| Google Drive 확장앱 | `https://www.googleapis.com/auth/drive.file` | 앱이 생성한 OPlayer 폴더에 파일을 업로드하고, 사용자가 확인한 앱 생성 파일을 덮어쓴다. 실제 Drive 웹에서도 결과를 확인한다. |
| Google Drive 동기화 확장앱 | `https://www.googleapis.com/auth/drive.appdata` | 재생목록·최근 재생·이어보기 위치를 저장한 뒤, 별도 기기에서 불러와 이어 재생한다. |

`drive.readonly`는 제한된 범위이며 `drive.file`·`drive.appdata`는 비민감 범위다. 범위를 줄였다는 이유만으로 readonly 심사까지 없어지는 것은 아니다. [Google Drive 권한 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

파일 접근과 동기화는 **서로 다른 연결·OAuth 흐름**이다. 파일 접근 로그인만 찍고 동기화 로그인 장면을 생략하지 않는다. 현재 공식 Drive 확장앱에는 파일 삭제·이름변경 기능이 없으므로 그 기능을 시연하거나 제공한다고 설명하지 않는다.

## 테스트 자료

| 자료 | 준비 방법 | 용도 |
| --- | --- | --- |
| `OPlayer OAuth Review Library` 폴더 | Google Drive 웹에서 미리 생성한다. | 앱이 만들지 않은 기존 폴더 탐색 증빙 |
| `existing-library.mp4` | 직접 제작한 2분 이상 테스트 영상을 위 폴더에 미리 업로드한다. 화면에 TEST MEDIA를 표시한다. | readonly 재생·검색·이어보기 증빙 |
| 업로드 영상 V1 | 화면에 UPLOAD VERSION 1을 표시한 짧은 테스트 파일을 촬영자가 관리하는 HTTPS 주소에서 제공한다. | 신규 업로드 증빙 |
| 업로드 영상 V2 | 화면에 UPLOAD VERSION 2를 표시하고 V1과 내용이 다른 파일을 별도 HTTPS 주소에서 제공한다. | 덮어쓰기 결과 증빙 |
| `oplayer-review-upload.mp4` | 두 업로드 작업에서 동일하게 입력할 저장 파일명이다. | 같은 앱 생성 파일의 갱신 증빙 |
| `OAuth Review Playlist` | A에서 촬영 중 생성한다. | 다른 기기에서 목록 복원 확인 |
| `OAuth Review Library` | 두 기기에서 Google Drive 리소스에 지정할 동일한 동기화 이름이다. | 기기마다 다른 연결 ID를 같은 파일 참조로 매핑 |

영상에는 개인 자료 대신 이 테스트 자료를 사용한다. V1·V2의 HTTPS 주소는 촬영 전에 실제 다운로드가 되는 주소로 준비한다. 원격 리소스의 **기기에 다운로드**는 로컬 복사 기능이므로 Drive 업로드 장면에는 사용하지 않는다.

## 촬영 순서

시간은 편집 계획용이다. 실제 전송 완료까지 기다린 뒤 최종 영상의 타임스탬프를 기록한다.

| 목표 구간 | 장면 | 화면에서 확인할 결과 |
| --- | --- | --- |
| 00:00~00:25 | 앱과 확장앱 소개 | OPlayer 이름·버전, 두 확장앱의 이름·버전 |
| 00:25~01:20 | Windows Drive 연결 | 실제 Google 동의 화면과 파일 접근 권한 |
| 01:20~02:10 | 기존 Drive 파일 탐색·재생 | 미리 올린 파일의 폴더 계층·검색·재생 |
| 02:10~03:00 | OPlayer 폴더 생성·신규 업로드 | 다운로드 후 클라우드 업로드 완료, Drive 웹의 V1 |
| 03:00~03:45 | 동일 파일 덮어쓰기 | 확인창과 Drive 웹의 V2 |
| 03:45~04:30 | Windows 동기화 연결 | 별도 Google 동의 흐름과 동기화 제공자 선택 |
| 04:30~05:25 | 기록 저장 | 동기화 이름·재생목록·45초 위치·동기화 성공 시각 |
| 05:25~07:40 | Android 연결·기록 복원 | 모바일 OAuth 흐름, 재생목록·기록·이어보기 복원 |
| 07:40~08:00 | 기능과 권한 정리 | 세 범위와 실제 사용 장면 요약 |

### 장면 1 앱 소개

Windows A에서 OPlayer를 연다. 앱 정보에서 버전을 보여주고 **설정 → 확장앱**으로 이동해 Google Drive와 Google Drive 동기화의 버전을 보여준다. 앱의 Google 기능은 사용자가 설치·활성화한 확장앱으로 제공된다고 설명한다.

영문 자막:

> OPlayer is a local and network media player. This video demonstrates Google Drive browsing, media playback, uploads, and playback history synchronization through the official extensions.

### 장면 2 Windows에서 Drive 파일 접근 연결

사이드바의 클라우드 **+**에서 **Google Drive**를 선택한다. Google 로그인·동의 과정을 화면에 담는다. 앱 이름, 테스트 계정, 펼친 권한 설명을 보여준 뒤 사용자가 승인한다. 앱으로 돌아와 연결된 계정이 표시되는 것까지 촬영한다.

심사자가 파일 접근 동의 화면에서 읽기 권한과 앱 파일 접근 권한을 읽을 수 있도록 잠시 멈춘다. 이미 연결된 목록만 보여주거나 동의 화면을 별도 이미지로 대체하지 않는다.

영문 자막:

> The Google Drive extension requests read-only access to existing Drive files and per-file access for files created or authorized for OPlayer. The user grants these permissions in Google's consent screen.

### 장면 3 기존 파일을 조회하고 재생

먼저 Drive 웹에서 `OPlayer OAuth Review Library/existing-library.mp4`가 있음을 보여준다. 이 파일은 OPlayer 연결 전에 업로드한 자료다. OPlayer로 돌아와 같은 폴더를 열고 파일명을 검색한다. 영상을 재생하고 중간 지점으로 이동해 실제 내용이 나오는 것을 보여준다.

영문 자막:

> This video already existed in the user's Drive before OPlayer was connected. Read-only access allows OPlayer to browse the folder hierarchy, find the file, and stream its media content without modifying it.

### 장면 4 신규 파일을 업로드

1. Windows A의 **설정 → 다운로드 → 저장 위치**에서 연결한 Google Drive 계정을 선택한다.
2. **저장할 폴더 선택**에서 OPlayer 전용 폴더를 선택·확정한다. 확장앱이 폴더를 생성하거나 기존 앱 전용 폴더를 재사용한다.
3. 내장 브라우저에서 업로드 영상 V1의 HTTPS 주소를 열어 다운로드를 시작한다. 파일명 입력창에 `oplayer-review-upload.mp4`를 입력한다.
4. 다운로드 목록에서 받기와 Google Drive 업로드가 모두 완료될 때까지 기다린다.
5. Drive 웹을 새로고침해 **내 드라이브 → OPlayer → oplayer-review-upload.mp4**를 확인하고 V1을 재생한다.

실제 최초 생성 증빙이 필요하면 해당 앱 전용 폴더가 없는 테스트 환경에서 시작한다. 이름만 같은 사용자 폴더가 앱 전용 폴더로 바뀐다고 설명하지 않는다.

영문 자막:

> The user chooses Google Drive as the download destination. OPlayer creates or reuses its own upload folder and uploads the requested file using drive.file access. The completed upload is visible in the user's Drive.

### 장면 5 사용자가 확인한 파일 덮어쓰기

V1 작업이 끝난 뒤 업로드 영상 V2의 별도 HTTPS 주소로 새 다운로드를 시작한다. 저장 파일명을 다시 `oplayer-review-upload.mp4`로 입력하고, 기존 파일 덮어쓰기 확인창을 보여준 뒤 사용자가 승인한다. 업로드가 완료되면 Drive 웹에서 같은 이름의 파일을 열어 V2가 재생되는 것을 보여준다. 필요하면 파일의 수정 시각도 함께 보여준다.

영문 자막:

> The user explicitly confirms replacing the previously uploaded file. OPlayer updates that app-authorized file. The same file now contains Upload Version 2, as shown in Google Drive.

### 장면 6 Windows에서 Google 동기화 연결

**설정 → 재생 동기화**로 이동한다. **동기화 확장앱**에서 **Google Drive 동기화**를 선택하고 **동기화 계정 연결**을 누른다. 파일 탐색 연결과 별개로 진행되는 실제 Google 로그인·권한 동의 과정을 촬영한다. 동의 화면을 English로 보여주고 승인 후 앱으로 돌아온다.

영문 자막:

> Playback synchronization has a separate authorization flow. The Google Drive sync extension requests drive.appdata to store and retrieve OPlayer's synchronization documents in the private application data folder.

### 장면 7 재생 기록을 저장

1. 재생 동기화 화면의 **기기별 폴더·리소스 연결**에서 A의 Google Drive 리소스에 동기화 이름 `OAuth Review Library`를 지정한다.
2. 파일 목록의 선택 모드 또는 파일 메뉴에서 `existing-library.mp4`를 **OAuth Review Playlist**에 추가한다.
3. 해당 영상을 약 **45초**까지 재생한 뒤 재생 화면에서 나와 최근 재생 항목과 위치를 확인한다. 끝까지 재생하지 않는다.
4. 재생 동기화 화면에서 **지금 동기화**를 누르고 성공 시각을 보여준다. B의 재생 전 동기화로 최신 기록이 바뀌지 않도록 이후 A에서 영상 재생을 더 진행하지 않는다.

숨겨진 appDataFolder 문서가 일반 Drive 파일 목록에 보인다고 설명하지 않는다. 저장 증빙은 다음 장면의 별도 기기 복원과 연결한다.

영문 자막:

> On Device A, the user assigns a shared library alias, creates a playlist, and stops playback at about 45 seconds. Sync Now saves the playlist, recent playback entry, and resume position to the app's private Drive data.

### 장면 8 Android에서 연결하고 기록을 복원

Android B의 화면을 녹화하고 **Device B — Android**라는 자막을 넣는다. A와 B가 같은 기기의 두 창이 아닌, 서로 독립된 설치 환경이라는 점이 보이게 전환한다. 연결을 시작하기 전에 B의 재생목록과 최근 재생이 비어 있는 화면을 먼저 담는다.

1. B에서 **Google Drive** 확장앱으로 같은 테스트 계정에 연결한다. Android의 실제 Google 파일 접근 동의 화면을 보여준다.
2. **설정 → 재생 동기화**에서 **Google Drive 동기화**를 선택하고 같은 계정에 연결한다. Android의 동기화 승인 흐름도 보여준다.
3. B의 Google Drive 리소스에도 동기화 이름 `OAuth Review Library`를 지정한다. 계정 연결 ID는 기기별로 달라도 이 이름과 Drive 파일 ID를 통해 같은 콘텐츠로 연결된다.
4. 복원되기 전 비어 있던 B의 목록과, 동기화 후 나타난 **OAuth Review Playlist**, 최근 재생 항목, 약 45초 위치를 보여준다. 첫 연결 때 자동 병합으로 이미 복원됐다면 그 시점을 그대로 촬영한다. 이후 **지금 동기화**와 성공 시각을 확인한다.
5. 자동 이어보기 설정을 확인한 뒤 해당 파일을 열고 저장된 위치 근처에서 재생되는 것을 보여준다. 이어보기 확인창이 나오면 직접 선택하는 장면도 남긴다.

영문 자막:

> Device B is a separate Android installation using the same Google account and Google Cloud project. After authorization and matching the library alias, it restores the playlist, recent playback entry, and resume position from Drive app data. Playback resumes near the saved 45-second position.

데스크톱 OAuth는 Windows에서, 모바일 네이티브 OAuth는 Android에서 실제 승인 흐름을 담는다. 심사팀이 요청한 OAuth 클라이언트 목록에 Android TV 등 다른 연결 경로가 포함돼 있으면 해당 실제 승인 화면을 보충 장면으로 추가한다.

### 장면 9 마무리

세 권한과 장면의 대응을 간단히 보여준다. 전체 Drive 관리 권한을 사용한다고 설명하지 않는다.

영문 자막:

> Read-only Drive access supports browsing and playback of existing media. drive.file supports user-requested uploads and confirmed replacement of app-authorized files. drive.appdata supports synchronization of playlists, recent playback, and resume positions between devices.

## 권한 필요성 영문 설명

아래 문구는 위 장면과 함께 제출할 설명 초안이다. 실제 촬영 결과와 일치하는지 확인한 뒤 사용한다.

### drive.readonly

OPlayer provides in-app folder browsing and streaming of media files that already exist in the user's Google Drive, including files created outside OPlayer. drive.file alone would limit access to app-created or individually authorized files and would not provide the existing library browsing demonstrated in this video. Metadata-only access would not allow OPlayer to read the media content for playback. The extension requests read-only access for this browsing and playback workflow.

### drive.file

The extension uses drive.file to create or reuse OPlayer's upload folder, create files requested by the user, and replace previously app-authorized files only after the user confirms the overwrite. The video shows the resulting new and updated content in Google Drive. The extension does not request full Drive management access for uploads.

### drive.appdata

The separate Google Drive sync extension reads and writes OPlayer synchronization documents in appDataFolder. These documents contain playlists, recent playback records, and resume positions. The video demonstrates saving on Device A and restoring on a separate Device B. Media files and authentication credentials are not included in the synchronization document.

## 최종 영상 확인

- 앱·확장앱 버전, Google Cloud 제출 범위, 두 연결의 실제 승인 화면, 홈페이지·정책 설명이 같은 기능을 가리키는지 확인한다.
- 동의 화면의 앱 이름·계정·권한과 주요 조작·완료 결과를 읽을 수 있게 유지한다. 비밀번호 입력 구간을 제외하더라도 실제 권한 승인 과정과 핵심 결과는 이어서 확인할 수 있어야 한다.
- V1 생성과 V2 덮어쓰기를 Drive 웹에서 확인한다. 업로드 진행률만으로 원격 저장 성공을 대신하지 않는다.
- B의 기록 복원은 별도 기기에서 확인한다. A를 다시 여는 것만으로 클라우드 복원을 증명하지 않는다.
- 실제 결과가 나오지 않으면 해당 장면을 다시 촬영한다. 앱 밖에서 수동으로 만든 결과를 OPlayer가 수행한 것처럼 붙이지 않는다.
- 영상 링크는 심사팀이 열 수 있도록 준비하고, 로그아웃한 브라우저에서도 열리는지 확인한다. 기존 심사 이메일에 답장할 때 영상 링크와 실제 타임스탬프를 넣는다. 이 문서를 작성하는 단계에서는 녹화·업로드·심사 제출을 진행하지 않는다.

## 심사 이메일 답장 초안

아래 대괄호는 최종 영상에 맞춰 채운다. 아직 촬영하지 않은 장면을 완료했다고 제출하지 않는다.

```text
Hello Google OAuth Verification Team,

We have updated OPlayer's Google Drive integration and prepared an updated demonstration video.

Video: [accessible video URL]
App version: [recorded version]

The file access extension requests:
- https://www.googleapis.com/auth/drive.readonly
- https://www.googleapis.com/auth/drive.file

The separate playback synchronization extension requests:
- https://www.googleapis.com/auth/drive.appdata

The extensions in this demonstration do not request https://www.googleapis.com/auth/drive.

Video sections:
- [timestamp] Application identity and extension versions
- [timestamp] Desktop OAuth consent for Drive file access
- [timestamp] Existing Drive folder browsing and media playback
- [timestamp] File upload and confirmation in Google Drive
- [timestamp] User-confirmed overwrite and updated content in Google Drive
- [timestamp] Separate OAuth consent for playback synchronization
- [timestamp] Saving playlists and playback progress on Device A
- [timestamp] Android authorization and restoration on Device B

The recording shows the functionality enabled by each requested scope. We have aligned the submitted scopes with the scopes requested by these extensions.

[Include homepage and privacy-policy URL updates here only if completed.]

Please let us know if any additional demonstration is required.

Best regards,
OPlayer Developer
```

## 촬영안과 구현의 연결

- [Google Drive 확장앱](../plugins/cloud.gdrive.js): 요청 범위, 조회·검색·재생, 전용 업로드 폴더, 신규 업로드·덮어쓰기.
- [Google Drive 동기화 확장앱](../plugins/sync.gdrive.js): appDataFolder의 문서 조회·읽기·쓰기.
- [재생 동기화 안내](google-sync.md): 기기별 리소스 이름 매핑과 동기화 동작.
- [Google 동영상 제출 안내](https://support.google.com/cloud/answer/13804565?hl=en): 실제 동의 흐름과 기능 촬영.
- [Google Drive 권한 분류](https://developers.google.com/workspace/drive/api/guides/api-specific-auth): 범위별 접근과 심사 분류.
