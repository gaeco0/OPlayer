import '../../core/settings.dart';

/// 클라우드 OAuth 앱 등록 정보.
///
/// 각 서비스 개발자 콘솔에서 앱을 만들고 아래 값을 채워야 로그인이 동작한다.
/// (빈 값이면 앱에서 "클라우드 설정 필요" 안내가 뜬다)
///
/// ■ Google Drive  — https://console.cloud.google.com/apis/credentials
///   · Drive API 사용 설정, OAuth 동의 화면 → 범위 drive.readonly
///   · 데스크톱(Windows/macOS): "데스크톱 앱" 클라이언트 → [googleDesktopClientId], [googleDesktopClientSecret]
///     리디렉션은 http://127.0.0.1:53682/callback (루프백, 자동 허용)
///   · Google 모바일 로그인은 추후 별도 구현한다.
///
/// ■ Dropbox — https://www.dropbox.com/developers/apps
///   · Scoped access, Full Dropbox, files.metadata.read + files.content.read + account_info.read
///   · Redirect URIs: http://localhost:53682/callback, com.oplayer.oplayer://oauth/dropbox
///
/// ■ OneDrive — https://entra.microsoft.com → 앱 등록
///   · 지원 계정: 개인 Microsoft 계정 포함, "공용 클라이언트 흐름 허용" 켜기
///   · 플랫폼: "모바일 및 데스크톱" → http://localhost:53682/callback,
///     com.oplayer.oplayer://oauth/onedrive 를 custom redirect URI로 등록
///   · API 권한: Files.Read, User.Read, offline_access
class CloudConfig {
  static const googleDesktopClientId = '';
  static const googleDesktopClientSecret = '';
  static const googleMobileClientId = '';

  static String get dropboxAppKey => AppSettings.instance.dropboxAppKey.isNotEmpty
      ? AppSettings.instance.dropboxAppKey
      : const String.fromEnvironment('DROPBOX_APP_KEY');

  static String get oneDriveClientId => AppSettings.instance.oneDriveClientId.isNotEmpty
      ? AppSettings.instance.oneDriveClientId
      : const String.fromEnvironment('ONEDRIVE_CLIENT_ID');
  static const mobileScheme = 'com.oplayer.oplayer';
  static const dropboxRedirect = '$mobileScheme://oauth/dropbox';
  static const oneDriveRedirect = '$mobileScheme://oauth/onedrive';

  /// 데스크톱 루프백 OAuth 포트 (Dropbox는 등록된 URI와 정확히 같아야 하므로 고정)
  static const loopbackPort = 53682;
}
