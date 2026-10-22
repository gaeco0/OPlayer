// @oplayer {"api":4,"id":"player.video-presets","name":"영상 색상 프리셋","version":"1.0.0","kind":"player","capabilities":["videoFilter"],"hosts":[],"settings":[{"key":"preset","type":"select","label":"프리셋","options":["원본","선명하게","흑백"],"default":"원본"}]}
globalThis.plugin = {
  videoFilter() {
    switch (OPlayer.config.preset) {
      case '선명하게': return {brightness:0, contrast:15, saturation:15};
      case '흑백': return {brightness:0, contrast:0, saturation:-100};
      default: return {brightness:0, contrast:0, saturation:0};
    }
  }
};
