#include "npu.h"
#include "layer_type.h"
#include "modelbin.h"
#include <algorithm>
#include <cctype>
#include <mutex>

static std::string lower(std::string s) {
  std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return (char)std::tolower(c);}); return s;
}
static bool has(const std::string& s,const char* part) { return s.find(part)!=std::string::npos; }
int npu_vendor(std::string maker,std::string soc,std::string hardware,std::string board) {
  maker=lower(maker);soc=lower(soc);hardware=lower(hardware);board=lower(board);
  if(has(maker,"google") || has(soc,"tensor") || soc.rfind("gs",0)==0) return 0;
  if(has(maker,"qualcomm") || has(soc,"snapdragon") || hardware=="qcom" ||
     (soc.size()>=6 && soc.rfind("sm",0)==0 && std::isdigit((unsigned char)soc[2]))) return 1;
  if(has(soc,"exynos") || has(hardware,"exynos") || has(board,"exynos") ||
     soc.rfind("s5e",0)==0 || board.rfind("s5e",0)==0) return 2;
  return 0;
}
bool npu_driver_allowed(int vendor,std::string name,int type) {
  if(type!=4) return false; // ANEURALNETWORKS_DEVICE_ACCELERATOR; never CPU/GPU/OTHER.
  name=lower(name);
  if(has(name,"cpu") || has(name,"gpu")) return false;
  return vendor==1 ? has(name,"qti") || has(name,"qualcomm") || has(name,"hexagon") :
    vendor==2 && (has(name,"exynos") || has(name,"samsung") || has(name,"enn"));
}

class NpuBlock final : public ncnn::Layer {
  NpuContext* context;
  int block=-1;
  std::vector<NpuWeights> weights;
  mutable std::vector<std::unique_ptr<ncnn::Layer>> reference;
  mutable std::unique_ptr<NpuGraph> graph;
  mutable int w=0,h=0,c=0;
  mutable std::mutex mutex;
  ncnn::Option cpu;
public:
  explicit NpuBlock(NpuContext* ctx):context(ctx) {
    one_blob_only=true; support_inplace=false; support_vulkan=false;
    cpu.num_threads=1;cpu.use_packing_layout=false;cpu.use_fp16_packed=false;cpu.use_fp16_storage=false;
    cpu.use_vulkan_compute=false;
  }
  ~NpuBlock() override {
    for(auto& layer:reference) if(layer) layer->destroy_pipeline(cpu);
  }
  int load_param(const ncnn::ParamDict& p) override {
    block=p.get(0,-1);return block>=0 && block<4 ? 0 : -1;
  }
  int load_model(const ncnn::ModelBin& mb) override {
    const auto& spec=npu_blocks[block];weights.resize(spec.count);reference.resize(spec.count);
    for(int i=0;i<spec.count;++i) if(spec.ops[i].kind==0) {
      weights[i].kernel=mb.load(spec.ops[i].weights,0);
      weights[i].bias=mb.load(spec.ops[i].out,1);
      if(weights[i].kernel.empty() || weights[i].bias.empty()) return -1;
    }
    return 0;
  }
  int forward(const ncnn::Mat& bottom,ncnn::Mat& top,const ncnn::Option&) const override {
    std::lock_guard<std::mutex> lock(mutex);
    if(bottom.elempack!=1 || bottom.elemsize!=4u) return -1;
    if(context && !context->reference_only && context->state!=3) {
      if(!graph || w!=bottom.w || h!=bottom.h || c!=bottom.c) {
        graph=compile_npu(*context,block,bottom,weights);w=bottom.w;h=bottom.h;c=bottom.c;
      }
      if(graph && graph->run(bottom,top)) { ++context->executions;context->state=2;return 0; }
      context->state=3;
    }
    // A failed driver must still return a valid tensor. The outer engine then
    // replaces this whole network with the original Vulkan network immediately.
    const auto& spec=npu_blocks[block];std::vector<ncnn::Mat> values(spec.count+1);values[0]=bottom;
    for(int i=0;i<spec.count;++i) {
      const auto& op=spec.ops[i];const auto& input=values[op.a];auto& out=values[i+1];
      if(op.kind==0) {
        if(!reference[i]) {
          auto layer=std::unique_ptr<ncnn::Layer>(ncnn::create_layer_cpu(ncnn::LayerType::Convolution));
          ncnn::ParamDict pd;pd.set(0,op.out);pd.set(1,op.kernel);pd.set(3,op.stride);
          pd.set(4,op.pad);pd.set(5,1);pd.set(6,op.weights);pd.set(9,op.activation);
          if(op.activation==2) {ncnn::Mat slope(1);slope[0]=op.slope;pd.set(10,slope);}
          ncnn::Mat data[]={weights[i].kernel,weights[i].bias};ncnn::ModelBinFromMatArray mb(data);
          if(!layer || layer->load_param(pd)!=0 || layer->load_model(mb)!=0 || layer->create_pipeline(cpu)!=0) return -1;
          reference[i]=std::move(layer);
        }
        if(reference[i]->forward(input,out,cpu)!=0) return -1;
      } else {
        out.create(input.w,input.h,input.c,4u,1);if(out.empty()) return -1;
        for(int q=0;q<input.c;++q) {
          const float* a=input.channel(q);float* dst=out.channel(q);
          const float* b=op.kind==1 ? (const float*)values[op.b].channel(q) : nullptr;
          for(int k=0;k<input.w*input.h;++k) dst[k]=b ? a[k]+b[k] : (a[k]<0 ? a[k]*op.slope : a[k]);
        }
      }
    }
    top=values.back();return 0;
  }
};
static ncnn::Layer* create_block(void* context) {return new NpuBlock((NpuContext*)context);}
void register_npu(ncnn::Net& net,NpuContext* context) {
  net.register_custom_layer("oplayer.NpuBlock",create_block,nullptr,context);
}

#ifndef __ANDROID__
std::shared_ptr<NpuContext> discover_npu(const std::string&) {return {};}
std::unique_ptr<NpuGraph> compile_npu(NpuContext&,int,const ncnn::Mat&,const std::vector<NpuWeights>&) {return {};}
#endif
