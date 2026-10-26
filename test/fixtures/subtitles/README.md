# Synthetic subtitle fixtures

All files here are generated for OPlayer's tests, with no film or third-party subtitles.

- `subtitle-bitmap.mkv`: four seconds of 160×90 black MPEG-4 video and a handcrafted
  PGS stream showing a 40×10 white rectangle from 0.1 to 3.9 seconds. The PGS stream
  uses a presentation, window, palette, RLE object and display-end segment;
  its only palette entry is opaque white. This exercises actual bitmap decoding
  and composition rather than an optimistic track selection flag.
- `subtitle-fixture.srt`: one English test cue.
- `subtitle-utf8.smi`: one Korean test cue, UTF-8.

Run `test/subtitle_native_test.dart` on Windows with `OPLAYER_TEST_LIBMPV` set to
the absolute path of the built `libmpv-2.dll`. The test checks that PGS changes
actual screenshot pixels, that SRT/SMI emit text, and that switching back disables
native OSD to avoid duplicate text. Ordinary tests skip this check when the native
library is unavailable; the shared Flutter layer is tested separately.
