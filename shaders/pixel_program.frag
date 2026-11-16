#include <flutter/runtime_effect.glsl>
uniform vec2 size;
uniform float count;
uniform vec4 code[64];
uniform sampler2D frame;
out vec4 fragColor;
vec3 safeDiv(vec3 a,vec3 b) {
 return a/(mix(vec3(1.0),vec3(-1.0),lessThan(b,vec3(0.0)))*max(abs(b),vec3(0.000001)));
}
vec3 readReg(int n,vec3 r0,vec3 r1,vec3 r2,vec3 r3,vec3 r4,vec3 r5,vec3 r6,vec3 r7) {
 if(n==0)return r0;if(n==1)return r1;if(n==2)return r2;if(n==3)return r3;
 if(n==4)return r4;if(n==5)return r5;if(n==6)return r6;return r7;
}
void main() {
 vec2 uv=FlutterFragCoord().xy/size;
 vec3 r0=vec3(0.0);
 vec3 r1=vec3(0.0);
 vec3 r2=vec3(0.0);
 vec3 r3=vec3(0.0);
 vec3 r4=vec3(0.0);
 vec3 r5=vec3(0.0);
 vec3 r6=vec3(0.0);
 vec3 r7=vec3(0.0);
 for(int j=0;j<64;j++) {
  if(float(j)>=count) break;
  vec4 i=code[j];
  int instruction=int(i.x),op=instruction/8,d=instruction-op*8;
  // Register indices are validated before upload, including initialized reads.
  int a=int(clamp(i.y,0.0,7.0)),b=int(clamp(i.z,0.0,7.0));
  vec3 av=readReg(a,r0,r1,r2,r3,r4,r5,r6,r7);
  vec3 bv=readReg(b,r0,r1,r2,r3,r4,r5,r6,r7);
  vec3 value=readReg(d,r0,r1,r2,r3,r4,r5,r6,r7);
  if(op==0) value=i.yzw;
  if(op==1 || op==2) {
   vec3 s=texture(frame,clamp(uv+i.yz/size,0.5/size,1.0-0.5/size)).rgb*i.w;
   if(op==1) value=s;else value+=s;
  }
  if(op==3) value=av+bv;
  if(op==4) value=av-bv;
  if(op==5) value=av*bv;
  if(op==6) value=safeDiv(av,bv);
  if(op==7) value=min(av,bv);
  if(op==8) value=max(av,bv);
  if(op==9) value=pow(max(av,vec3(0.000001)),clamp(bv,vec3(-16.0),vec3(16.0)));
  if(op==10) value=clamp(av,vec3(i.z),vec3(i.w));
  if(op==11) value=vec3(dot(av,bv));
  if(op==12) value=av;
  if(op==13) value=vec3(uv,0.0);
  if(op==14) value=sin(av);
  if(op==15) value=abs(av);
  if(op==16) {float v=dot(av,bv);if(i.w<0.5)value.r=v;else if(i.w<1.5)value.g=v;else value.b=v;}
  if(op==17) value=exp(clamp(av,vec3(-16.0),vec3(16.0)));
  if(op==18) value=sqrt(max(av,vec3(0.0)));
  if(op==19) value=cos(av);
  if(op==20) value=floor(av);
  if(d==0)r0=value;
  if(d==1)r1=value;
  if(d==2)r2=value;
  if(d==3)r3=value;
  if(d==4)r4=value;
  if(d==5)r5=value;
  if(d==6)r6=value;
  if(d==7)r7=value;
 }
 fragColor=vec4(clamp(r0,0.0,1.0),1.0);
}
