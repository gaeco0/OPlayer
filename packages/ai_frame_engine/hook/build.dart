import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;
    final buildDir = input.outputDirectory.resolve('cmake-v1/');
    await Directory.fromUri(buildDir).create(recursive: true);
    var cmake = 'cmake';
    if (Platform.isWindows) {
      for (final edition in ['Community', 'Professional', 'Enterprise', 'BuildTools']) {
        final candidate =
            'C:/Program Files/Microsoft Visual Studio/18/$edition/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe';
        if (File(candidate).existsSync()) {
          cmake = candidate;
          break;
        }
      }
    }
    if (Platform.isWindows && !(await Process.run('where.exe', ['cmake'])).stdout.toString().contains('cmake')) {
      final vs = '${Platform.environment['ProgramFiles']}\\Microsoft Visual Studio\\2022';
      for (final edition in ['Community', 'Professional', 'Enterprise', 'BuildTools']) {
        final candidate = '$vs\\$edition\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe';
        if (File(candidate).existsSync()) {
          cmake = candidate;
          break;
        }
      }
    }
    final options = <String>[
      '-S',
      input.packageRoot.resolve('native/').toFilePath(),
      '-B',
      buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
      '-DCMAKE_LIBRARY_OUTPUT_DIRECTORY=${buildDir.toFilePath()}',
      '-DCMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE=${buildDir.toFilePath()}',
    ];
    if (os == OS.windows) {
      final vs18 =
          (code.cCompiler?.compiler.path.contains('/18/') ?? false) ||
          Directory('C:/Program Files/Microsoft Visual Studio/18').existsSync();
      options.addAll([
        '-G',
        vs18 ? 'Visual Studio 18 2026' : 'Visual Studio 17 2022',
        '-A',
        arch == Architecture.arm64 ? 'ARM64' : 'x64',
      ]);
    } else if (os == OS.android) {
      final compiler = code.cCompiler?.compiler;
      if (compiler == null) throw StateError('Android NDK compiler is missing');
      final ndk = File.fromUri(compiler).parent.parent.parent.parent.parent.parent;
      options.addAll([
        '-G',
        'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=${ndk.path}/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=${switch (arch) {
          Architecture.arm64 => 'arm64-v8a',
          Architecture.arm => 'armeabi-v7a',
          Architecture.x64 => 'x86_64',
          _ => throw UnsupportedError('$arch'),
        }}',
        '-DANDROID_PLATFORM=android-${code.android.targetNdkApi}',
        '-DANDROID_STL=c++_static',
      ]);
      if (Platform.isWindows) {
        final cmakeRoot = Directory('${ndk.parent.parent.path}/cmake');
        if (await cmakeRoot.exists()) {
          final installs = await cmakeRoot.list().where((e) => e is Directory).toList();
          installs.sort((a, b) => b.path.compareTo(a.path));
          for (final install in installs) {
            final ninja = File('${install.path}/bin/ninja.exe');
            if (await ninja.exists()) {
              options.add('-DCMAKE_MAKE_PROGRAM=${ninja.path}');
              break;
            }
          }
        }
      }
    } else if (os == OS.macOS) {
      options.addAll([
        '-DCMAKE_OSX_ARCHITECTURES=${arch == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}.0',
      ]);
    } else if (os != OS.linux) {
      throw UnsupportedError('RIFE is not built for $os');
    }
    Future<void> run(List<String> arguments) async {
      final result = await Process.run(cmake, arguments);
      if (result.exitCode != 0) throw StateError('RIFE build failed:\n${result.stdout}\n${result.stderr}');
    }

    await run(options);
    await run(['--build', buildDir.toFilePath(), '--config', 'Release', '--parallel', '4']);
    final name = os == OS.windows
        ? 'oplayer_rife.dll'
        : os == OS.macOS
        ? 'liboplayer_rife.dylib'
        : 'liboplayer_rife.so';
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'engine.dart',
        linkMode: DynamicLoadingBundled(),
        file: buildDir.resolve(name),
      ),
    );
    output.dependencies.addAll(
      await Directory.fromUri(
        input.packageRoot.resolve('native/'),
      ).list(recursive: true).where((e) => e is File).map((e) => e.uri).toList(),
    );
  });
}
