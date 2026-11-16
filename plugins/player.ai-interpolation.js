// @oplayer {"api":5,"id":"player.ai-interpolation","name":"AI 보간 모델","version":"1.1.0","kind":"player","capabilities":["interpolation"],"hosts":["raw.githubusercontent.com"],"description":"확장앱 제공 RIFE 모델·프레임 처리 프로그램·NPU/GPU 실행 정책","platforms":["android","windows","linux","macos"],"requiresHost":["playerOptions","frameProcessing"],"settings":[{"key":"accelerator","label":"AI 보간 실행 장치","type":"select","options":["자동","GPU"],"default":"자동","description":"자동은 지원되는 NPU를 우선 사용하고 미지원 시 GPU를 사용합니다."}]}
globalThis.plugin = {
  validateSettings() {
    if (!['자동','GPU'].includes(OPlayer.config.accelerator)) return '지원되는 실행 장치를 선택하세요.';
    return null;
  },
  playbackOptions(c) {
    const result = {ai:false,npu:false,issue:null};
    if (!c.visible || c.casting || c.bitmapSubtitles || c.rate !== 1 || c.fastForwarding) return {...result,issue:'이 모델은 화면에서 비트맵 자막 없이 1배속으로 재생할 때 사용할 수 있습니다.'};
    if (['pq','hlg'].includes(c.gamma)) return {...result,issue:'이 프레임 처리 모델은 SDR 영상만 지원합니다.'};
    return {ai:true,npu:c.platform === 'android' && OPlayer.config.accelerator !== 'GPU',issue:null};
  },
  frameProcessor({id}) {
    if (id !== 'rife-v4-6') throw new Error('Unknown interpolation model');
    return {engine:'rife-v4.6',inputFrames:2,outputFrames:1,artifacts:[{"name":"flownet-npu.param","sha256":"517561e5affe42e39c6c8328675139104228cc8454c2dfd54d06a6f6bf74106c","url":"https://raw.githubusercontent.com/gaeco0/OPlayer/main/assets/models/rife-v4.6/flownet-npu.param"},{"name":"flownet.bin","sha256":"f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958","url":"https://raw.githubusercontent.com/gaeco0/OPlayer/main/assets/models/rife-v4.6/flownet.bin"},{"name":"flownet.param","sha256":"724569596bcd1e7b9fa50455c604777ebed99746d2ef40aa86e31b5725f1053c","url":"https://raw.githubusercontent.com/gaeco0/OPlayer/main/assets/models/rife-v4.6/flownet.param"}]};
  },
  interpolationModels() {
    return [{id:'rife-v4-6',name:'RIFE v4.6 · 실시간 AI 보간',engine:'rife-v4.6',description:'이전·현재 프레임으로 중간 프레임 생성 · 1배속 SDR · 320px 처리 · 250ms 지연 · NPU/GPU 자동 선택'}];
  }
};
