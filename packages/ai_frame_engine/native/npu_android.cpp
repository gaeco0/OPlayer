#ifdef __ANDROID__
// Only declarations are used for dlsym types: do not import newer symbols on
// older Android releases. All calls go through the validated function pointers.
#define __ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ 1
#include "npu.h"
#include "upscale.h"
#include <android/NeuralNetworks.h>
#include <dlfcn.h>
#include <sys/system_properties.h>
#include <filesystem>
#include <array>
#include <stdexcept>
#include <algorithm>

// Resolve API 29+ at runtime so Android 24–28 and non-NPU devices still load.
static_assert(ANEURALNETWORKS_DEVICE_ACCELERATOR == 4);
struct Api {
  void* library=nullptr;
#define NN_FUNCTIONS(X) \
  X(ANeuralNetworks_getDeviceCount) X(ANeuralNetworks_getDevice) \
  X(ANeuralNetworksDevice_getName) X(ANeuralNetworksDevice_getType) \
  X(ANeuralNetworksDevice_getVersion) X(ANeuralNetworksDevice_getFeatureLevel) \
  X(ANeuralNetworksModel_create) X(ANeuralNetworksModel_free) \
  X(ANeuralNetworksModel_addOperand) X(ANeuralNetworksModel_setOperandValue) \
  X(ANeuralNetworksModel_addOperation) X(ANeuralNetworksModel_identifyInputsAndOutputs) \
  X(ANeuralNetworksModel_relaxComputationFloat32toFloat16) X(ANeuralNetworksModel_finish) \
  X(ANeuralNetworksModel_getSupportedOperationsForDevices) \
  X(ANeuralNetworksCompilation_createForDevices) X(ANeuralNetworksCompilation_setPreference) \
  X(ANeuralNetworksCompilation_setCaching) X(ANeuralNetworksCompilation_finish) \
  X(ANeuralNetworksCompilation_free) X(ANeuralNetworksExecution_create) \
  X(ANeuralNetworksExecution_setInput) X(ANeuralNetworksExecution_setOutput) \
  X(ANeuralNetworksExecution_compute) X(ANeuralNetworksExecution_free)
#define DECLARE(name) decltype(&name) name=nullptr;
  NN_FUNCTIONS(DECLARE)
#undef DECLARE
  decltype(&ANeuralNetworksCompilation_setTimeout) compile_timeout=nullptr;
  decltype(&ANeuralNetworksExecution_setTimeout) execution_timeout=nullptr;
  bool ready=false;
  Api() {
    library=dlopen("libneuralnetworks.so",RTLD_NOW|RTLD_LOCAL);if(!library) return;
#define LOAD(name) name=reinterpret_cast<decltype(name)>(dlsym(library,#name));if(!name) return;
    NN_FUNCTIONS(LOAD)
#undef LOAD
    compile_timeout=reinterpret_cast<decltype(compile_timeout)>(dlsym(library,"ANeuralNetworksCompilation_setTimeout"));
    execution_timeout=reinterpret_cast<decltype(execution_timeout)>(dlsym(library,"ANeuralNetworksExecution_setTimeout"));
    ready=true;
  }
};
static Api& api() {static Api value;return value;}
static std::string property(const char* key) {
  char value[PROP_VALUE_MAX]={};__system_property_get(key,value);return value;
}
std::shared_ptr<NpuContext> discover_npu(const std::string& directory) {
  auto context=std::make_shared<NpuContext>();
  context->vendor=npu_vendor(property("ro.soc.manufacturer"),property("ro.soc.model"),
    property("ro.hardware"),property("ro.board.platform"));
  if(!context->vendor) return {};
  auto& nn=api();context->state=3;
  if(!nn.ready) return context;
  uint32_t count=0;if(nn.ANeuralNetworks_getDeviceCount(&count)!=0) return context;
  for(uint32_t i=0;i<count;++i) {
    ANeuralNetworksDevice* device=nullptr;const char *name=nullptr,*version=nullptr;
    int32_t type=0;int64_t feature=0;
    if(nn.ANeuralNetworks_getDevice(i,&device)!=0 || nn.ANeuralNetworksDevice_getName(device,&name)!=0 ||
       nn.ANeuralNetworksDevice_getType(device,&type)!=0 || nn.ANeuralNetworksDevice_getFeatureLevel(device,&feature)!=0 ||
       feature<3 || !name || !npu_driver_allowed(context->vendor,name,type)) continue;
    nn.ANeuralNetworksDevice_getVersion(device,&version);
    context->devices.push_back({device,name,version?version:""});
  }
  if(!context->devices.empty()) {
    context->state=1;context->cache=directory+"/npu-cache-v1";
    std::error_code error;std::filesystem::create_directories(context->cache,error);
    if(error) context->cache.clear();
  }
  return context;
}

static void check(int result) {if(result!=ANEURALNETWORKS_NO_ERROR) throw std::runtime_error("NNAPI rejected RIFE block");}
class AndroidGraph final : public NpuGraph {
  Api& nn=api();
  ANeuralNetworksModel* model=nullptr;
  ANeuralNetworksCompilation* compilation=nullptr;
  uint32_t next=0,operation_count=0;
  std::vector<std::vector<float>> constants;
  int iw=0,ih=0,ic=0,ow=0,oh=0,oc=0;
  std::vector<float> input,output;
  uint32_t tensor(const std::vector<uint32_t>& shape) {
    ANeuralNetworksOperandType type{ANEURALNETWORKS_TENSOR_FLOAT32,(uint32_t)shape.size(),shape.data(),0,0};
    check(nn.ANeuralNetworksModel_addOperand(model,&type));return next++;
  }
  uint32_t scalar(int32_t value) {
    ANeuralNetworksOperandType type{ANEURALNETWORKS_INT32,0,nullptr,0,0};
    check(nn.ANeuralNetworksModel_addOperand(model,&type));const auto id=next++;
    check(nn.ANeuralNetworksModel_setOperandValue(model,id,&value,sizeof(value)));return id;
  }
  uint32_t constant(std::vector<float> data,const std::vector<uint32_t>& shape) {
    const auto id=tensor(shape);constants.push_back(std::move(data));
    const auto& values=constants.back();
    check(nn.ANeuralNetworksModel_setOperandValue(model,id,values.data(),values.size()*sizeof(float)));return id;
  }
  void operation(int kind,const std::vector<uint32_t>& in,uint32_t out) {
    check(nn.ANeuralNetworksModel_addOperation(model,kind,in.size(),in.data(),1,&out));++operation_count;
  }
  uint32_t prelu(uint32_t source,float slope,const std::vector<uint32_t>& shape) {
    const auto alpha=constant({slope},{1}),out=tensor(shape);
    operation(ANEURALNETWORKS_PRELU,{source,alpha},out);return out;
  }
public:
  ~AndroidGraph() override {
    if(compilation) nn.ANeuralNetworksCompilation_free(compilation);
    if(model) nn.ANeuralNetworksModel_free(model);
  }
  void build(NpuContext& context,int block,const ncnn::Mat& bottom,const std::vector<NpuWeights>& weights) {
    iw=bottom.w;ih=bottom.h;ic=bottom.c;
    check(nn.ANeuralNetworksModel_create(&model));
    struct Value {uint32_t id;std::vector<uint32_t> shape;};
    std::vector<Value> values{{tensor({1,(uint32_t)ih,(uint32_t)iw,(uint32_t)ic}),{1,(uint32_t)ih,(uint32_t)iw,(uint32_t)ic}}};
    const auto none=scalar(ANEURALNETWORKS_FUSED_NONE);
    const auto& spec=npu_blocks[block];
    for(int i=0;i<spec.count;++i) {
      const auto& op=spec.ops[i];const auto& a=values[op.a];
      auto shape=a.shape;uint32_t id=0;
      if(op.kind==0) {
        const int channels=op.weights/(op.out*op.kernel*op.kernel);
        if(channels!=(int)shape[3]) throw std::runtime_error("RIFE channel mismatch");
        std::vector<float> filter(op.weights);const float* source=weights[i].kernel;
        for(int out=0;out<op.out;++out) for(int y=0;y<op.kernel;++y)
          for(int x=0;x<op.kernel;++x) for(int in=0;in<channels;++in)
            filter[((out*op.kernel+y)*op.kernel+x)*channels+in]=source[((out*channels+in)*op.kernel+y)*op.kernel+x];
        const auto kernel=constant(std::move(filter),{(uint32_t)op.out,(uint32_t)op.kernel,(uint32_t)op.kernel,(uint32_t)channels});
        const float* bias=weights[i].bias;
        const auto b=constant(std::vector<float>(bias,bias+op.out),{(uint32_t)op.out});
        shape[1]=(shape[1]+2*op.pad-op.kernel)/op.stride+1;
        shape[2]=(shape[2]+2*op.pad-op.kernel)/op.stride+1;shape[3]=op.out;
        id=tensor(shape);const auto pad=scalar(op.pad),stride=scalar(op.stride);
        operation(ANEURALNETWORKS_CONV_2D,{a.id,kernel,b,pad,pad,pad,pad,stride,stride,none},id);
        if(op.activation==2) id=prelu(id,op.slope,shape);
      } else if(op.kind==1) {
        const auto& b=values[op.b];if(b.shape!=shape) throw std::runtime_error("RIFE residual mismatch");
        id=tensor(shape);operation(ANEURALNETWORKS_ADD,{a.id,b.id,none},id);
      } else id=prelu(a.id,op.slope,shape);
      values.push_back({id,shape});
    }
    finish(context,values.front().id,values.back().id,values.back().shape,"rife-v4.6-f334ed2260149ce0-block-v1:"+std::to_string(block));
  }
  void finish(NpuContext& context,uint32_t input_id,uint32_t output_id,const std::vector<uint32_t>& shape,const std::string& identity) {
    check(nn.ANeuralNetworksModel_identifyInputsAndOutputs(model,1,&input_id,1,&output_id));
    check(nn.ANeuralNetworksModel_relaxComputationFloat32toFloat16(model,true));
    check(nn.ANeuralNetworksModel_finish(model));
    auto supported=std::make_unique<bool[]>(operation_count);
    for(const auto& candidate:context.devices) {
      const auto device=(const ANeuralNetworksDevice*)candidate.handle;
      if(nn.ANeuralNetworksModel_getSupportedOperationsForDevices(model,&device,1,supported.get())!=0) continue;
      bool all=true;for(uint32_t i=0;i<operation_count;++i) all=all && supported[i];
      if(!all) continue;
      if(nn.ANeuralNetworksCompilation_createForDevices(model,&device,1,&compilation)!=0) {
        if(compilation) nn.ANeuralNetworksCompilation_free(compilation);
        compilation=nullptr;continue;
      }
      if(nn.compile_timeout) nn.compile_timeout(compilation,5000000000ull);
      nn.ANeuralNetworksCompilation_setPreference(compilation,ANEURALNETWORKS_PREFER_SUSTAINED_SPEED);
      if(!context.cache.empty()) {
        std::array<uint8_t,32> token{};
        const auto key=identity+":"+
          std::to_string(iw)+":"+std::to_string(ih)+":"+std::to_string(ic)+":"+candidate.name+":"+candidate.version;
        // Cache identity only; model authenticity is checked separately by SHA-256.
        for(int j=0;j<4;++j) {uint64_t hash=1469598103934665603ull+j;
          for(unsigned char c:key) {hash^=c;hash*=1099511628211ull;}
          for(int k=0;k<8;++k) token[j*8+k]=(uint8_t)(hash>>(k*8));}
        nn.ANeuralNetworksCompilation_setCaching(compilation,context.cache.c_str(),token.data());
      }
      if(nn.ANeuralNetworksCompilation_finish(compilation)==0) break;
      nn.ANeuralNetworksCompilation_free(compilation);compilation=nullptr;
    }
    if(!compilation) throw std::runtime_error("No allowed NPU supports the full RIFE CNN block");
    oh=shape[1];ow=shape[2];oc=shape[3];
    input.resize(iw*ih*ic);output.resize(ow*oh*oc);
  }
  uint32_t integers(const std::vector<int32_t>& data) {
    const uint32_t shape[]={(uint32_t)data.size()};
    ANeuralNetworksOperandType type{ANEURALNETWORKS_TENSOR_INT32,1,shape,0,0};
    check(nn.ANeuralNetworksModel_addOperand(model,&type));const auto id=next++;
    check(nn.ANeuralNetworksModel_setOperandValue(model,id,data.data(),data.size()*4));return id;
  }
  void build_upscale(NpuContext& context,const UpscaleNetwork& network,const ncnn::Mat& bottom,const std::string& identity) {
    iw=bottom.w;ih=bottom.h;ic=bottom.c;check(nn.ANeuralNetworksModel_create(&model));
    const std::vector<uint32_t> base={1,(uint32_t)ih,(uint32_t)iw,(uint32_t)ic};
    std::vector<uint32_t> values{tensor(base)};std::vector<int> channels{ic};
    const auto none=scalar(0),zero=constant({0},{1}),one=scalar(1),axis=scalar(3);
    for(const auto& op:network.ops) {
      std::vector<uint32_t> sources;int count=0;
      for(auto edge:op.inputs) {
        auto id=values[edge.first];const std::vector<uint32_t> shape={1,(uint32_t)ih,(uint32_t)iw,(uint32_t)channels[edge.first]};
        if(edge.second==2){const auto out=tensor(shape);operation(ANEURALNETWORKS_NEG,{id},out);id=out;}
        if(edge.second){const auto out=tensor(shape);operation(ANEURALNETWORKS_MAXIMUM,{id,zero},out);id=out;}
        sources.push_back(id);count+=channels[edge.first];
      }
      std::vector<uint32_t> shape={1,(uint32_t)ih,(uint32_t)iw,(uint32_t)count};
      uint32_t id=sources.front();
      if(sources.size()>1){const auto out=tensor(shape);sources.push_back(axis);operation(ANEURALNETWORKS_CONCATENATION,sources,out);id=out;}
      // texOff uses clamp-to-edge. Two integer gathers reproduce it exactly,
      // including corners, rather than silently substituting zero padding.
      const int pad=op.kernel/2;
      if(pad){
        std::vector<int32_t> ys(ih+pad*2),xs(iw+pad*2);
        for(int i=0;i<(int)ys.size();++i)ys[i]=std::clamp(i-pad,0,ih-1);
        for(int i=0;i<(int)xs.size();++i)xs[i]=std::clamp(i-pad,0,iw-1);
        shape[1]=ys.size();auto out=tensor(shape);operation(ANEURALNETWORKS_GATHER,{id,scalar(1),integers(ys)},out);id=out;
        shape[2]=xs.size();out=tensor(shape);operation(ANEURALNETWORKS_GATHER,{id,scalar(2),integers(xs)},out);id=out;
      }
      const auto filter=constant(op.weights,{4,(uint32_t)op.kernel,(uint32_t)op.kernel,(uint32_t)count});
      const auto bias=constant(op.bias,{4});shape={1,(uint32_t)ih,(uint32_t)iw,4};
      auto out=tensor(shape);const auto z=scalar(0);
      operation(ANEURALNETWORKS_CONV_2D,{id,filter,bias,z,z,z,z,one,one,none},out);id=out;
      if(!op.alpha.empty()){out=tensor(shape);operation(ANEURALNETWORKS_PRELU,{id,constant(op.alpha,{4})},out);id=out;}
      values.push_back(id);channels.push_back(4);
    }
    finish(context,values.front(),values.back(),{1,(uint32_t)ih,(uint32_t)iw,4},"upscale-clamp-v1:"+identity);
  }
  bool run(const ncnn::Mat& bottom,ncnn::Mat& top) override {
    for(int q=0;q<ic;++q) {const float* src=bottom.channel(q);
      for(int i=0;i<iw*ih;++i) input[i*ic+q]=src[i];}
    ANeuralNetworksExecution* execution=nullptr;
    if(nn.ANeuralNetworksExecution_create(compilation,&execution)!=0) return false;
    if(nn.execution_timeout) nn.execution_timeout(execution,500000000ull);
    const bool ok=nn.ANeuralNetworksExecution_setInput(execution,0,nullptr,input.data(),input.size()*sizeof(float))==0 &&
      nn.ANeuralNetworksExecution_setOutput(execution,0,nullptr,output.data(),output.size()*sizeof(float))==0 &&
      nn.ANeuralNetworksExecution_compute(execution)==0;
    nn.ANeuralNetworksExecution_free(execution);if(!ok) return false;
    top.create(ow,oh,oc,4u,1);if(top.empty()) return false;
    for(int q=0;q<oc;++q) {float* dst=top.channel(q);
      for(int i=0;i<ow*oh;++i) dst[i]=output[i*oc+q];}
    return true;
  }
};
std::unique_ptr<NpuGraph> compile_npu(NpuContext& context,int block,const ncnn::Mat& input,const std::vector<NpuWeights>& weights) {
  try {auto graph=std::make_unique<AndroidGraph>();graph->build(context,block,input,weights);return graph;}
  catch(...) {return {};}
}
std::unique_ptr<NpuGraph> compile_upscale(NpuContext& context,const UpscaleNetwork& network,const ncnn::Mat& input,const std::string& identity) {
  try{auto graph=std::make_unique<AndroidGraph>();graph->build_upscale(context,network,input,identity);return graph;}
  catch(...){return {};}
}
#endif
