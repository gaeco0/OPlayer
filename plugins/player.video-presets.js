// @oplayer {"api":5,"id":"player.video-presets","name":"동영상 필터","version":"1.1.0","kind":"player","capabilities":["videoFilter"],"requiresHost":["pixelPrograms"],"hosts":[],"description":"부드럽게·선명하게·색온도·흑백을 동시에 적용합니다. 설정과 처리 프로그램을 확장앱이 제공합니다.","settings":[{"key":"smoothing","type":"select","label":"부드럽게","options":["끄기","약하게","보통","강하게"],"default":"끄기"},{"key":"sharpening","type":"select","label":"선명하게","options":["끄기","약하게","보통","강하게"],"default":"끄기"},{"key":"temperature","type":"select","label":"색온도","options":["차갑게","약간 차갑게","중립","약간 따뜻하게","따뜻하게"],"default":"중립"},{"key":"grayscale","type":"boolean","label":"흑백","default":false}],"platforms":["android","windows","linux","macos"]}
// All effect choices and executable math live here, not in the host.
function options() {
 const c=OPlayer.config;
 return {smoothing:c.smoothing || '끄기',sharpening:c.sharpening || '끄기',
  temperature:c.temperature || '중립',grayscale:c.grayscale===true};
}
function convolution(kernel,divisor) {
 const code=[[0,0,0,0]]; // constant register 0 = black
 kernel.forEach((weight,i)=>{if(weight)code.push([16,i%3-1,Math.floor(i/3)-1,weight/divisor]);}); // sample-add
 code.push([80,0,0,1]); // clamp register 0 to [0,1]
 return code;
}
globalThis.plugin={
 validateSettings() {
  const c=options();
  if(![c.smoothing,c.sharpening].every(v=>['끄기','약하게','보통','강하게'].includes(v)) ||
     !['차갑게','약간 차갑게','중립','약간 따뜻하게','따뜻하게'].includes(c.temperature) ||
     (OPlayer.config.grayscale!==undefined && typeof OPlayer.config.grayscale!=='boolean')) {
   throw new Error('영상 필터 옵션을 다시 선택하세요');
  }
  return null;
 },
 // Backwards scalar contract; new hosts use the program below instead.
 videoFilter() {return {brightness:0,contrast:0,saturation:OPlayer.config.preset==='흑백' ? -100 : 0};},
 frameProcessor() {
  const c=options(),passes=[];
  if(c.smoothing!=='끄기') {
   const center=[24,8,2][['약하게','보통','강하게'].indexOf(c.smoothing)];
   passes.push(convolution([1,2,1,2,center,2,1,2,1],center+12));
  }
  if(c.sharpening!=='끄기') {
   const scale=[8,4,2][['약하게','보통','강하게'].indexOf(c.sharpening)];
   passes.push(convolution([0,-1,0,-1,scale+4,-1,0,-1,0],scale));
  }
  const balance={'차갑게':[0.86,0.96,1.12],'약간 차갑게':[0.94,0.98,1.06],
   '약간 따뜻하게':[1.06,0.99,0.92],'따뜻하게':[1.12,0.97,0.82]}[c.temperature] || [1,1,1];
  if(c.temperature!=='중립' || c.grayscale) {
   const code=[[9,0,0,1],[0,0,0,0]]; // sample register 1, clear output register 0
   for(let row=0;row<3;row++) {
    const rgb=[0,1,2].map(col=>balance[row]*(c.grayscale ? [0.2126,0.7152,0.0722][col] : row===col ? 1 : 0));
    code.push([2,...rgb],[128,1,2,row]); // constant register 2, dot into output component
   }
   passes.push(code);
  }
  return {engine:'pixel-program-v1',inputFrames:1,outputFrames:1,passes};
 }
};
