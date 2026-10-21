# Android FFmpeg

The Android application dynamically links the non-GPL `min` build:

- Maven: `io.github.jamaismagic.ffmpeg:ffmpeg-kit-main-min-16kb:6.1.4`
- Source, native wrapper, and build scripts: https://github.com/JamaisMagic/ffmpeg-kit-16KB
- Artifact and POM: https://repo.maven.apache.org/maven2/io/github/jamaismagic/ffmpeg/ffmpeg-kit-main-min-16kb/6.1.4/
- License: LGPL-3.0; included in `assets/licenses/ffmpeg-kit.txt` and shown through the Android FFmpeg settings tile.

The min variant includes FFmpeg's built-in muxers, demuxers, and bitstream filters. Downloads use `-c copy`; additional encoding libraries are unnecessary. The wrapper is called with an argument array so filenames are not shell commands. Existing desktop FFmpeg discovery remains in use on desktop platforms.
