enum UpdateChannel { stable, beta, nightly }

class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.name, this.parts, this.pre);
  final String name;
  final List<int> parts;
  final List<String> pre;
  UpdateChannel get channel => pre.isEmpty ? UpdateChannel.stable : UpdateChannel.values.byName(pre.first);

  static AppVersion? parse(String value) {
    if (value.length > 100) return null;
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-((?:beta|nightly)\.[0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 3; i++) int.tryParse(match[i]!)];
    if (parts.contains(null)) return null;
    final pre = match[4]?.split('.') ?? <String>[];
    if (pre.any((p) => p.isEmpty)) return null;
    return AppVersion._('${parts.join('.')}${pre.isEmpty ? '' : '-${pre.join('.')}'}', parts.cast<int>(), pre);
  }

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    // Within one base version, our release stages advance nightly -> beta -> stable.
    final stage = other.channel.index.compareTo(channel.index);
    if (stage != 0) return stage;
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty
          ? 0
          : pre.isEmpty
          ? 1
          : -1;
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = int.tryParse(pre[i]), b = int.tryParse(other.pre[i]);
      final result = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : pre[i].compareTo(other.pre[i]);
      if (result != 0) return result;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

class ReleaseAsset {
  ReleaseAsset(this.name, this.url, this.size, this.digest);
  final String name;
  final Uri url;
  final int size;
  final String? digest;
}

class AppRelease {
  AppRelease(this.version, this.notes, this.url, this.assets);
  final AppVersion version;
  final String notes;
  final Uri url;
  final List<ReleaseAsset> assets;

  static AppRelease? parse(Map data) {
    final version = AppVersion.parse('${data['tag_name']}');
    if (data['draft'] != false ||
        version == null ||
        (data['prerelease'] == true) != (version.channel != UpdateChannel.stable)) {
      return null;
    }
    final assets = <ReleaseAsset>[];
    for (final asset in (data['assets'] is List ? data['assets'] as List : const []).whereType<Map>()) {
      final name = asset['name'];
      final url = Uri.tryParse('${asset['browser_download_url']}');
      final size = asset['size'];
      if (name is! String ||
          url == null ||
          size is! int ||
          size <= 0 ||
          size > 1024 * 1024 * 1024 ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          url.port != 443 ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment ||
          url.path != '/gaeco0/OPlayer/releases/download/v${version.name}/$name' ||
          name.contains('/') ||
          name.contains('\\')) {
        continue;
      }
      final digest = asset['digest'];
      assets.add(
        ReleaseAsset(
          name,
          url,
          size,
          digest is String && RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)
              ? digest.substring(7).toLowerCase()
              : null,
        ),
      );
    }
    if (!assets.any((a) => a.name == 'SHA256SUMS.txt')) return null;
    return AppRelease(
      version,
      data['body'] is String ? data['body'] as String : '',
      Uri.https('github.com', '/gaeco0/OPlayer/releases/tag/v${version.name}'),
      assets,
    );
  }

  ReleaseAsset? assetFor(String target, {bool tv = false, List<String> abis = const []}) {
    final prefix = 'OPlayer-${version.name}-';
    final names = target == 'android'
        ? [for (final abi in abis) '${prefix}android-${tv ? 'tv' : 'mobile'}-$abi.apk']
        : ['$prefix$target${target.startsWith('linux-') ? '.tar.gz' : '.zip'}'];
    for (final name in names) {
      for (final asset in assets) {
        if (asset.name == name) return asset;
      }
    }
    return null;
  }
}

AppRelease? latestRelease(Iterable<AppRelease> releases, UpdateChannel channel) {
  final matching = releases.where((r) => r.version.channel.index <= channel.index).toList()
    ..sort((a, b) => b.version.compareTo(a.version));
  return matching.firstOrNull;
}
