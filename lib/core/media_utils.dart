import 'package:path/path.dart' as p;

const videoExtensions = {
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.wmv',
  '.flv',
  '.webm',
  '.m4v',
  '.ts',
  '.m2ts',
  '.mts',
  '.3gp',
  '.mpg',
  '.mpeg',
  '.vob',
  '.ogv',
  '.rmvb',
  '.asf',
};

const subtitleExtensions = {'.srt', '.smi', '.ass', '.ssa', '.vtt', '.sub', '.sup'};
const audioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.flac',
  '.wav',
  '.ogg',
  '.opus',
  '.wma',
  '.aiff',
  '.alac',
  '.mka',
};
const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif'};

bool isVideo(String path) => videoExtensions.contains(p.extension(path).toLowerCase());
bool isAudio(String path) => audioExtensions.contains(p.extension(path).toLowerCase());
bool isImage(String path) => imageExtensions.contains(p.extension(path).toLowerCase());
bool isPlayable(String path) => isVideo(path) || isAudio(path) || p.extension(path).toLowerCase() == '.m3u8';
bool isBrowsableMedia(String path) => isPlayable(path) || isImage(path);
bool isSubtitle(String path) => subtitleExtensions.contains(p.extension(path).toLowerCase());

/// "EP2" < "EP10" 이 되도록 숫자 부분은 숫자로 비교.
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ma = re.allMatches(a.toLowerCase()).toList();
  final mb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i].group(0)!, y = mb[i].group(0)!;
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ma.length.compareTo(mb.length);
}

String formatDuration(Duration d, {bool forceHours = false}) {
  final neg = d.isNegative;
  d = d.abs();
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final body = (h > 0 || forceHours) ? '$h:$m:$s' : '$m:$s';
  return neg ? '-$body' : body;
}

String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// 같은 폴더에서 동영상과 이름이 같은 자막 파일을 찾는다 (movie.mkv → movie.srt / movie.ko.smi ...)
List<String> siblingSubtitles(String videoPath, Iterable<String> folderFiles) {
  final base = p.basenameWithoutExtension(videoPath).toLowerCase();
  return folderFiles.where((f) => isSubtitle(f) && p.basename(f).toLowerCase().startsWith(base)).toList();
}
