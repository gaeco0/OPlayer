# Bundled lightweight AI upscalers

These are trained CNN weights encoded as mpv GLSL shaders. The JavaScript provider embeds the original shader sources without modification. Standalone editable originals are provided as anime4k-s.glsl, anime4k-denoise-s.glsl and fsrcnnx-8.glsl in this directory. Default models are available offline; additional installed JS providers use the same host contract. No provider is automatically installed in PluginStore.

- **Anime4K CNN S** (MIT): https://raw.githubusercontent.com/bloc97/Anime4K/7684e9586f8dcc738af08a1cdceb024cc184f426/glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl
  - SHA-256: `4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4`
- **Anime4K Denoise CNN S** (MIT): https://raw.githubusercontent.com/bloc97/Anime4K/7684e9586f8dcc738af08a1cdceb024cc184f426/glsl/Upscale%2BDenoise/Anime4K_Upscale_Denoise_CNN_x2_S.glsl
  - SHA-256: `1a45ad3aa20d8368399f2fd46791deed957c2fd0a4afd131cc92516827abab93`
- **FSRCNNX 8** (LGPL-3.0-or-later): https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1/FSRCNNX_x2_8-0-4-1.glsl
  - SHA-256: `e800dbc5c1c95185cc82216c597724533ff5f2880179f256eef600f03e8dc2ae`

Anime4K sources: revision `7684e9586f8dcc738af08a1cdceb024cc184f426`. Original notices are preserved in the shader strings. FSRCNNX shader source is distributed in editable form; license text is bundled with the application. These are lightweight candidates, not a guarantee of real-time performance on every device.
