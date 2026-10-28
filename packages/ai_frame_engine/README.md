# OPlayer AI frame engine

Native RIFE v4.6 frame interpolation. This package does not replace mpv's decoder,
audio device, network transport, or playback controls. Dart native asset hooks
compile and bundle a shared library for Windows, Android/TV, Linux and macOS.
Requires Dart >=3.10 and CMake >=3.22, plus the platform C++ toolchain. Android
uses the SDK-provided NDK toolchain and Ninja. Release workflows remain tag-triggered.

## Pinned inputs

- RIFE source and v4.6 weights: `nihui/rife-ncnn-vulkan` revision
  `a7532fc3f9f8f008cd6eecd6f2ffe2a9698e0cf7` (MIT).
- ncnn: official `20261020` full-source release ZIP, SHA-256
  `699d9acc67489eee0993a551ca1ebc247bbf0f4e33babe1dec810e6a9a52b988`.
  Includes pinned glslang; no unpinned build-time Git checkout.
- Public mpv client ABI header: mpv v0.40.0 (ISC).
- Model SHA-256 values are checked by the app and `test/ai_interpolation_test.dart`.
  Models are bundled in `assets/models/rife-v4.6`, not fetched from arbitrary URLs.
  Upscaling GLSL URL models remain a separate API.
- Complete third-party notices: `assets/licenses/ai-interpolation.txt`.

Changes to upstream: Unicode-safe model paths, load-error propagation and avoiding
a null Vulkan device setter in CPU mode in `rife.cpp`; disable the removed ncnn
Vulkan pack8 option in `warp.cpp`.
The wrapper and build configuration are OPlayer code. The RIFE loader also
registers an optional custom CNN block layer and loads a generated NPU graph;
original weights, deconvolution, warping and resizing remain unchanged.

## Playback contract

One native worker captures mpv's raw video frame with its presentation time (`time-pos`), respects
row stride, downsizes to an even resolution with a maximum 320px long side and
generates an actual RIFE midpoint. GPU inference uses Vulkan when available;
CPU inference remains available. Performance varies by device.

The bounded queue holds at most 32 BGRA frames. UI polling copies only a due
frame, never a pointer into a mutable queue. A 250ms display delay lets the next
source frame arrive. The controller adds the same delay to user audio/subtitle
offsets only while generated output is displayed, and restores those offsets
when returning to the original texture. Decoder and audio playback remain mpv's.

Seek/discontinuity/size change clears the queue. Unsupported speed, capture or
model errors, sustained inference over the source frame budget, or stalled output
return to the original display. Shutdown is asynchronous: request stop, wait for
the worker, then dispose mpv. The UI never joins an active GPU worker synchronously.
One inference worker can run at a time; another player receives a visible failure.

The app currently limits this mode to SDR, 1x playback, 10–60fps input and text subtitles.
Bitmap subtitles, casting, background playback and simultaneous upscaling use
the original renderer instead. The original frame-mixing option is independent.

## Verification

- `flutter test test/ai_interpolation_test.dart`: preference persistence, pinned
  model hashes, real CPU neural inference, missing model handling and a moving
  rectangle whose midpoint differs from frame blending.
- `dart run tool/ai_interpolation_probe.dart [--cpu]`: native CPU/Vulkan probe
  using the bundled model directly from the repository assets.
- `flutter run -d windows --debug -t tool/ai_interpolation_smoke.dart`: native
  playback, output cadence, pause, seek, disable and unsupported-speed fallback.
  Requires a >=30s 24fps moving fixture with audio at `.dart_tool/rife-playback.mp4`.
  Result is written to `.dart_tool/rife-playback-result.json`.

Android, Linux, macOS and ARM64 device performance must be measured separately;
successful cross-compilation does not verify playback or GPU compatibility.

Windows x64 validation on AMD Radeon 890M: 24fps moving input produced 145 UI
frames in 3s with approximately 9.6ms inference, and pause/seek/disable/speed
fallback passed. CPU neural midpoint and model-error tests passed. Windows must
explicitly load the system Vulkan runtime: the old loader bundled with ANGLE
crashes with current AMD drivers. Android ARM64 cross-build passed with NDK
28.2.13676358; Android playback has not been measured on a device.

## Android NPU (Snapdragon / Exynos only)

The Android-only preference defaults to on, while interpolation itself remains
off by default. SoC properties must identify Snapdragon/Qualcomm or Exynos;
Samsung device branding alone does not qualify, and Tensor is excluded.
Only matching NNAPI `DEVICE_ACCELERATOR` drivers are accepted. CPU, GPU, OTHER
and unknown drivers are rejected. `createForDevices` explicitly targets one
allowed accelerator, with every operation checked first; NNAPI CPU fallback is
never presented as NPU inference.

Four CNN blocks (convolution, leaky ReLU, residual addition) use NNAPI; ncnn
Vulkan retains the surrounding operations. `tool/generate_rife_npu.py --check`
verifies generated graph/metadata against the pinned original graph. The weight
stream is unchanged. CPU fused-graph inference is compared numerically with the
original network. This verifies graph rewriting, not vendor NPU accuracy.

NNAPI symbols are resolved via dlsym at runtime (Android 10+), preserving older
Android loading. NNAPI is deprecated and some firmware no longer exposes a
compatible accelerator. No Qualcomm/Samsung SDK binaries are bundled. Unsupported
operations, compilation/execution failure, or sustained slow inference switch
the entire engine back to its original GPU path (CPU if Vulkan is unavailable).
The fallback reference computation produces a valid tensor for the failing
invocation before the network is replaced. Device/version/model/shape-specific
compilation caches are kept in app-private model storage. When available, NNAPI
compilation/execution timeout hints are set; drivers remain responsible for
honoring them. UI status reports NPU only after a successful real invocation.

Verification: the test suite covers SoC/driver policy and CPU graph equivalence;
`dart run tool/ai_interpolation_probe.dart --fused [--cpu]` exercises the rewritten
network with reference CNN blocks, including Vulkan/CPU tensor transfers without
requiring an NPU. Android ARM64 cross-compilation and ELF checks are separate.
Physical Snapdragon/Exynos playback, driver support and performance remain
unverified. GLSL upscaling is GPU-only; this option applies only to RIFE.
