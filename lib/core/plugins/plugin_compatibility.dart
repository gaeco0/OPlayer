import 'dart:io';

const pluginHostApi = 5;
const pluginPlatforms = ['android', 'ios', 'windows', 'linux', 'macos'];

Set<String> pluginHostFeatures(String platform) => {
  if (['android', 'windows', 'linux', 'macos'].contains(platform)) 'googlePicker',
  if (['android', 'ios', 'windows', 'macos'].contains(platform)) 'webBrowser',
};

/// Shared by catalog UI, import, activation and invocation. Pure platform input
/// keeps all supported OS combinations testable on every CI runner.
String? pluginCompatibilityIssue(Map<String, dynamic> manifest, {String? platform}) {
  platform ??= Platform.operatingSystem;
  if (((manifest['api'] ?? manifest['pluginApi']) as int? ?? 1) > pluginHostApi) return '앱 업데이트가 필요한 확장앱입니다';
  final declared = manifest['platforms'] as List?;
  if (declared != null && !declared.contains(platform)) return '$platform에서 지원하지 않는 확장앱입니다';
  final features = pluginHostFeatures(platform);
  if (['browser', 'site'].contains(manifest['kind']) && !features.contains('webBrowser')) {
    return '$platform에서는 내장 브라우저 확장앱을 지원하지 않습니다';
  }
  for (final required in manifest['requiresHost'] as List? ?? const []) {
    if (!features.contains(required)) return '앱 업데이트 또는 다른 OS가 필요합니다: $required ($platform)';
  }
  return null;
}
