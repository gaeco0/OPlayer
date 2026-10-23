# OPlayer video output patch

Upstream: media_kit_video 2.0.1 from pub.dev, https://github.com/media-kit/media-kit.
The upstream MIT license is preserved in LICENSE. Source only; no additional
media engine or prebuilt binaries are bundled by this patch.

AndroidVideoController now implements the existing setSize API using its existing
SetSurfaceSize channel. The requested dimensions are retained when videoParams
changes. Passing null restores the source dimensions, including rotated videos.
Resizing is serialized with the existing controller lock and skips identical sizes
to avoid repeated surface recreation/seeks. Resize waits for the native callback
and times out if the Surface producer never confirms the requested size, allowing
the caller to restore the original output. The video widget documentation reflects
this Android GPU output support. Other platform implementations are unchanged.

Keep this change when updating the upstream package, or remove the local package
when upstream provides equivalent Android setSize behavior.

Windows ARM64: use the pinned ARM64 ANGLE import library and EGL export aliases supplied by windows/arm64-libraries.cmake; x64 rendering is unchanged.
