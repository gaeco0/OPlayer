// @oplayer {"api":4,"id":"player.ai-interpolation","name":"AI 보간 모델","version":"1.0.0","kind":"player","capabilities":["interpolation"],"hosts":[],"description":"실시간 RIFE v4.6 보간 모델 · 지원 엔진이 포함된 앱 필요"}
globalThis.plugin = {
  interpolationModels() {
    return [{id:"rife-v4-6", name:"RIFE v4.6 · 실시간 AI 보간", engine:"rife-v4.6"}];
  }
};
