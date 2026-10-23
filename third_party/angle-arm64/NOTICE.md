# Windows ARM64 media dependencies

The original x64 media_kit native dependencies are unchanged.

- libmpv ARM64: media-kit/libmpv-win32-video-cmake, release `20241021`,
  `mpv-dev-aarch64-20241021-git-0f78584.7z`.
  Build sources: https://github.com/media-kit/libmpv-win32-video-cmake/tree/20241021
  This is the upstream mpv/FFmpeg build, with its upstream component licenses;
  see https://github.com/media-kit/libmpv-win32-video-cmake and https://mpv.io/copyright/.
- ANGLE ARM64: `Avalonia.Angle.Windows.Natives` `2.1.27548.20260419` (BSD-style license in LICENSE).
  Source: https://github.com/AvaloniaUI/angle/tree/1c89805903c1482166356d3b950d474973180e61
  The package combines EGL/GLES in `av_libglesv2.dll`. We generate an ARM64 import
  library and map `egl*` API names to its `EGL_*` exports at compile time.
  Existing media_kit ANGLE headers remain architecture independent.
- WebView2 ARM64 loader: Microsoft.Web.WebView2 `1.0.4258.31`.
  Package: https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4258.31
  Distributed under Microsoft's WebView2 SDK license included in the NuGet package.

Downloads use pinned versions and checksums in `windows/arm64-libraries.cmake`.
No binary is obtained from a moving latest URL.
