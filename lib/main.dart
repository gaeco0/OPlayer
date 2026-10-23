import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app/theme.dart';
import 'app/media_shell.dart';
import 'core/mouse_nav.dart';
import 'core/linux_file_associations.dart';
import 'core/resume_store.dart';
import 'core/playlist_store.dart';
import 'core/settings.dart';
import 'core/plugins/plugin_store.dart';
import 'core/resource_locks.dart';
import 'features/settings/privacy_settings.dart';
import 'core/network/network_service.dart';
import 'features/web/download_manager.dart';
import 'sources/server_store.dart';
import 'features/browser/home_screen.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'QuickJS-NG',
      'quickjs_engine',
    ], await rootBundle.loadString('assets/licenses/quickjs.txt'));
    yield LicenseEntryWithLineBreaks(const ['ByeDPI'], await rootBundle.loadString('assets/licenses/byedpi.txt'));
    yield LicenseEntryWithLineBreaks(
      const ['FFmpeg', 'FFmpegKit'],
      'Android: ffmpeg-kit-main-min-16kb 6.1.4 (LGPL-3.0).\n'
      'Source and build scripts: https://github.com/JamaisMagic/ffmpeg-kit-16KB\n\n'
      '${await rootBundle.loadString('assets/licenses/ffmpeg-kit.txt')}',
    );
  });
  MediaKit.ensureInitialized();
  await Future.wait([
    ResumeStore.instance.init(),
    PlaylistStore.instance.init(),
    AppSettings.instance.init(),
    ServerStore.instance.init(),
    DownloadManager.instance.init(),
  ]);
  await NetworkService.instance.init();
  await PluginStore.instance.init();
  await ResourceLocks.instance.init();
  await ResourceLocks.instance.syncNativePrivacy();
  if (ResourceLocks.supportsSystemAuthentication) {
    final enabled = await privacyChannel.invokeMethod<bool>('getCaptureProtection') ?? false;
    if (enabled != AppSettings.instance.preventCapture) AppSettings.instance.update((s) => s.preventCapture = enabled);
  }
  MouseNav.installKeyHandler();
  unawaited(registerLinuxFileAssociations());
  runApp(OPlayerApp(initialFiles: args));
}

class OPlayerApp extends StatelessWidget {
  const OPlayerApp({super.key, this.initialFiles = const []});
  final List<String> initialFiles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => MaterialApp(
        title: 'OPlayer',
        navigatorKey: MouseNav.navigatorKey,
        builder: (context, child) => MouseNavListener(
          child: PrivacyShell(
            child: MediaShell(initialFiles: initialFiles, child: child!),
          ),
        ),
        debugShowCheckedModeBanner: false,
        theme: OTheme.light(),
        darkTheme: OTheme.dark(),
        themeMode: ThemeMode.values.byName(AppSettings.instance.themeMode.name),
        home: const HomeScreen(),
      ),
    );
  }
}
