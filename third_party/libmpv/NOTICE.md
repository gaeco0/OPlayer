# libmpv subtitle-capable builds

OPlayer dynamically links libmpv; the application's MIT LICENSE is unchanged.
The native libraries are LGPL builds, not the GPL encoder flavor. Library files
can be replaced with compatible user-built versions. LGPLv3 and its incorporated
GPLv3 text are included here and in the app's open-source licenses screen.

## Windows x64 / ARM64

- Distributor/build recipe: https://github.com/zhongfly/mpv-winbuild
- Pinned release: https://github.com/zhongfly/mpv-winbuild/releases/tag/2026-10-25-baa3e11d42
- Use `mpv-dev-lgpl-x86_64-20261025-git-baa3e11d42.7z` and
  `mpv-dev-lgpl-aarch64-20261025-git-baa3e11d42.7z` (baseline x64, not x64-v3).
- mpv source: https://github.com/mpv-player/mpv/tree/baa3e11d42
- Build sources/configuration: the pinned release's source archive and
  https://github.com/zhongfly/mpv-winbuild/tree/2026-10-25-baa3e11d42
- SHA-256 hashes are pinned in `windows/mpv-libraries.cmake` and verified before extraction.
- The build extracts with official 7-Zip 25.01 (`7zr.exe`), pinned and SHA-256 checked,
  to support ARM64 BCJ compression: https://github.com/ip7z/7zip/releases/tag/25.01.
  This build tool is not bundled in OPlayer.
- Rebuild using the distributor's recipe with its LGPL variant. Dependencies retain
  their own licenses; source recipes enumerate them. The resulting library is a
  separate `libmpv-2.dll` in the application directory.

## Android (mobile and TV)

- Upstream recipe/source release: https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.11
- `full` flavor; includes subtitle decoders absent from `default`.
- Native dependencies and build scripts: https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.11
- SHA-256 hashes for all four official ABI JARs are pinned in
  `packages/media_kit_libs_android_video/android/build.gradle`.
- The Android Java integration is copied from `media_kit_libs_android_video` 1.3.8,
  under its MIT license; its original LICENSE is preserved in that package.
- Rebuilding the JARs from the pinned upstream source and updating their hashes
  replaces the dynamically linked `libmpv.so` without changing OPlayer's Dart code.

mpv: https://github.com/mpv-player/mpv

FFmpeg: https://github.com/FFmpeg/FFmpeg

libass: https://github.com/libass/libass
