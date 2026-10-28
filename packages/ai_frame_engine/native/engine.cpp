#include "rife.h"
#include "npu.h"
#include "mpv/client.h"
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <filesystem>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <objbase.h>
#endif

#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
using Clock = std::chrono::steady_clock;
using Get = int (*)(mpv_handle*, const char*, mpv_format, void*);
using Command = int (*)(mpv_handle*, const char**, mpv_node*);
using Free = void (*)(mpv_node*);
constexpr double latency = .250;
static std::mutex inferenceMutex; // ncnn's process-global GPU lifetime and pipelines.
struct Frame { double pts; int w, h; std::vector<unsigned char> pixels; };
struct Engine {
  std::atomic<bool> stop{false}, finished{false};
  std::atomic<int> state{0}, error{0}, generated{0};
  std::atomic<double> milliseconds{0};
  std::atomic<bool> pausedFlag{false};
  std::atomic<bool> gpu{false};
  bool prefer_npu=true;
  std::shared_ptr<NpuContext> npu;
  std::mutex mutex;
  std::deque<Frame> frames;
  std::thread thread;
  mpv_handle* mpv;
  Get get; Command command; Free freeNode;
  double sourcePts = 0;
  bool paused = false;
  Clock::time_point captured = Clock::now();
};
static std::unique_ptr<RIFE> model(const char* path, int gpu, NpuContext* npu=nullptr, bool* used_gpu=nullptr) {
  bool available=false;
  if (gpu) {
    static const bool initialized = [] {
#ifdef _WIN32
      // ANGLE ships a 2022 Vulkan loader beside the app. It crashes with some
      // current AMD drivers; resolve the OS loader explicitly for this engine.
      char directory[MAX_PATH];
      const auto length=GetSystemDirectoryA(directory,MAX_PATH);
      if(!length || length>=MAX_PATH) return false;
      const std::string loader=std::string(directory)+"\\vulkan-1.dll";
      if(GetFileAttributesA(loader.c_str())==INVALID_FILE_ATTRIBUTES) return false;
      return ncnn::create_gpu_instance(loader.c_str())==0;
#else
      return ncnn::create_gpu_instance()==0;
#endif
    }();
    available=initialized && ncnn::get_gpu_count()>0;
  }
  const int device = available ? ncnn::get_default_gpu_index() : -1;
  if(used_gpu) *used_gpu=available;
  auto net = std::make_unique<RIFE>(device, false, false, false, 2, false, true);
#ifdef _WIN32
  if (net->load(std::filesystem::u8path(path).wstring(),npu) != 0) return {};
#else
  if (net->load(std::string(path),npu) != 0) return {};
#endif
  return net;
}
static bool interpolate(RIFE& net, const Frame& a, const Frame& b, Frame& mid) {
  const int w = a.w, h = a.h;
  std::vector<unsigned char> pa(w*h*3), pb(w*h*3), out(w*h*3);
#ifdef _WIN32
  const int conversion = ncnn::Mat::PIXEL_BGRA2BGR;
  const int packed = ncnn::Mat::PIXEL_BGR;
#else
  const int conversion = ncnn::Mat::PIXEL_BGRA2RGB;
  const int packed = ncnn::Mat::PIXEL_RGB;
#endif
  ncnn::Mat::from_pixels(a.pixels.data(), conversion, w, h).to_pixels(pa.data(), packed);
  ncnn::Mat::from_pixels(b.pixels.data(), conversion, w, h).to_pixels(pb.data(), packed);
  ncnn::Mat ma(w, h, pa.data(), (size_t)3, 1), mb(w, h, pb.data(), (size_t)3, 1);
  ncnn::Mat mo(w, h, out.data(), (size_t)3, 1);
  if (net.process(ma, mb, .5f, mo) != 0) return false;
  mid = {(a.pts+b.pts)*.5, w, h, std::vector<unsigned char>(w*h*4)};
  for (int i=0; i<w*h; ++i) {
#ifdef _WIN32
    mid.pixels[4*i]=out[3*i]; mid.pixels[4*i+2]=out[3*i+2];
#else
    mid.pixels[4*i]=out[3*i+2]; mid.pixels[4*i+2]=out[3*i];
#endif
    mid.pixels[4*i+1]=out[3*i+1]; mid.pixels[4*i+3]=255;
  }
  return true;
}
static bool screenshot(Engine& e, Frame& frame) {
  mpv_node result{};
  const char* args[] = {"screenshot-raw", "video", nullptr};
  if (e.command(e.mpv, args, &result) < 0) return false;
  int w=0,h=0,stride=0; mpv_byte_array* bytes=nullptr; bool bgra=false;
  if (result.format == MPV_FORMAT_NODE_MAP) {
    auto list = result.u.list;
    for (int i=0;i<list->num;++i) {
      auto& node=list->values[i]; auto key=list->keys[i];
      if (node.format==MPV_FORMAT_INT64) {
        if (!strcmp(key,"w")) w=(int)node.u.int64;
        if (!strcmp(key,"h")) h=(int)node.u.int64;
        if (!strcmp(key,"stride")) stride=(int)node.u.int64;
      }
      if (!strcmp(key,"data") && node.format==MPV_FORMAT_BYTE_ARRAY) bytes=node.u.ba;
      if (!strcmp(key,"format") && node.format==MPV_FORMAT_STRING)
        bgra=!strcmp(node.u.string,"bgr0") || !strcmp(node.u.string,"bgra");
    }
  }
  bool ok=false;
  if (bgra && w>0 && h>0 && w<=8192 && h<=8192 && stride>=w*4 && bytes && bytes->size >= (size_t)stride*h) {
    // Bound inference cost and memory even for 4K/8K input. Keep source aspect.
    const double scale=std::min(1.,320./std::max(w,h));
    frame.w=std::max(2,(int)(w*scale)/2*2); frame.h=std::max(2,(int)(h*scale)/2*2);
    frame.pixels.resize(frame.w*frame.h*4);
    auto resized=ncnn::Mat::from_pixels_resize((unsigned char*)bytes->data, ncnn::Mat::PIXEL_BGRA,
      w,h,stride,frame.w,frame.h);
    resized.to_pixels(frame.pixels.data(),ncnn::Mat::PIXEL_BGRA);
    for(size_t i=3;i<frame.pixels.size();i+=4) frame.pixels[i]=255;
    ok=true;
  }
  e.freeNode(&result);
  return ok;
}
static void run(Engine& e, std::string path) {
  struct Completion {
    Engine& engine;
#ifdef _WIN32
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
#endif
    ~Completion() {
#ifdef _WIN32
      if(SUCCEEDED(apartment)) CoUninitialize();
#endif
      engine.finished=true;
    }
  } completion{e};
  try {
    std::unique_lock<std::mutex> inference(inferenceMutex,std::try_to_lock);
    if (!inference.owns_lock()) { e.error=6; e.state=2; return; }
    auto context=e.prefer_npu ? discover_npu(path) : nullptr;
    {std::lock_guard<std::mutex> lock(e.mutex);e.npu=context;}
    bool using_npu=context && context->state==1,used_gpu=false;
    auto net=model(path.c_str(),1,using_npu ? context.get() : nullptr,&used_gpu);
    e.gpu=used_gpu;
    if (!net) { e.error=1; e.state=2; return; }
    Frame previous{}; int slow=0, failures=0; double last=-1, fps=24;
    e.get(e.mpv,"container-fps",MPV_FORMAT_DOUBLE,&fps);
    if(std::isfinite(fps) && fps>0 && (fps<10 || fps>60)) {e.error=7; e.state=2; return;}
    if(!std::isfinite(fps) || fps<=0) fps=24;
    while (!e.stop) {
      int paused=0, caching=0; double pts=0, speed=1;
      e.get(e.mpv,"pause",MPV_FORMAT_FLAG,&paused);
      e.get(e.mpv,"paused-for-cache",MPV_FORMAT_FLAG,&caching);
      paused=paused || caching;
      e.pausedFlag=paused!=0;
      e.get(e.mpv,"speed",MPV_FORMAT_DOUBLE,&speed);
      if (std::abs(speed-1)>.001) { e.error=4; break; }
      if (e.get(e.mpv,"time-pos",MPV_FORMAT_DOUBLE,&pts)<0 || !std::isfinite(pts)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue;
      }
      {
        std::lock_guard<std::mutex> lock(e.mutex); e.paused=paused!=0;
      }
      if (std::abs(pts-last)<.0001) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
      Frame current{}; current.pts=pts;
      if (!screenshot(e,current)) {
        if (++failures>40) {e.error=2; break;}
        std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue;
      }
      failures=0;
      const double delta=pts-last;
      if (previous.pixels.empty() || delta<.005 || delta>.150 || current.w!=previous.w || current.h!=previous.h) {
        std::lock_guard<std::mutex> lock(e.mutex);
        e.frames.clear(); e.frames.push_back(current); e.state=0;
        e.sourcePts=pts; e.captured=Clock::now();
      } else {
        Frame middle{};
        auto before=Clock::now();
        const bool valid=interpolate(*net,previous,current,middle);
        if(using_npu && (!valid || context->state==3)) {
          context->state=3;using_npu=false;net.reset();net=model(path.c_str(),1,nullptr,&used_gpu);e.gpu=used_gpu;
          if(!net) {e.error=3;break;}
          previous=Frame{};last=-1;slow=0;e.state=0;continue;
        }
        if(!valid) {e.error=3;break;}
        const double ms=std::chrono::duration<double,std::milli>(Clock::now()-before).count();
        e.milliseconds=ms; ++e.generated;
        // Allow shader warm-up, then require sustained throughput with headroom.
        if (e.generated>6 && ms>900./fps) ++slow; else slow=std::max(0,slow-1);
        if (slow>=8) {
          if(using_npu) {
            context->state=3;using_npu=false;net.reset();net=model(path.c_str(),1,nullptr,&used_gpu);e.gpu=used_gpu;
            if(!net) {e.error=3;break;}
            previous=Frame{};last=-1;slow=0;e.generated=0;e.state=0;continue;
          }
          e.error=5;break;
        }
        std::lock_guard<std::mutex> lock(e.mutex);
        e.frames.push_back(std::move(middle)); e.frames.push_back(current);
        while (e.frames.size()>32) e.frames.pop_front();
        e.sourcePts=pts; e.captured=before;
        if (e.generated>=4) e.state=1;
      }
      previous=std::move(current); last=pts;
    }
  } catch (...) { e.error=3; }
  e.state=e.error ? 2 : 3;
}
API Engine* oplayer_rife_start(const char* path, void* mpv, void* get, void* command, void* freeNode, int prefer_npu) {
  if (!path || !mpv || !get || !command || !freeNode) return nullptr;
  try {
    auto e=std::make_unique<Engine>(); e->mpv=(mpv_handle*)mpv; e->get=(Get)get; e->command=(Command)command; e->freeNode=(Free)freeNode;
    e->prefer_npu=prefer_npu!=0;
    e->thread=std::thread(run,std::ref(*e),std::string(path)); return e.release();
  } catch (...) { return nullptr; }
}
// The caller owns a 320*320*4 buffer. No shared pixel pointer escapes the lock.
API int oplayer_rife_poll(Engine* e, unsigned char* pixels, int* info, double* timing) {
  info[0]=e->state; info[1]=e->error; info[2]=e->generated; info[5]=e->pausedFlag ? 1 : 0;
  {std::lock_guard<std::mutex> lock(e->mutex);
    info[6]=e->npu ? (int)e->npu->state : 0;info[7]=e->npu ? (int)e->npu->executions : 0;info[8]=e->gpu ? 1 : 0;}
  timing[0]=e->milliseconds;
  if (e->state!=1) return 0;
  std::lock_guard<std::mutex> lock(e->mutex);
  const double elapsed=e->paused ? 0 : std::min(latency,std::chrono::duration<double>(Clock::now()-e->captured).count());
  const double target=e->sourcePts+elapsed-latency;
  if (e->frames.empty() || e->frames.front().pts>target) return 0;
  while(e->frames.size()>1 && e->frames[1].pts<=target) e->frames.pop_front();
  auto& f=e->frames.front();
  if (target-f.pts>.150) return -1; // Do not leave a frozen overlay over moving audio.
  info[3]=f.w;info[4]=f.h;timing[1]=f.pts;
  std::memcpy(pixels,f.pixels.data(),f.pixels.size()); return 1;
}
API void oplayer_rife_stop(Engine* e) { e->stop=true; }
API int oplayer_rife_finished(Engine* e) { return e->finished ? 1 : 0; }
API void oplayer_rife_destroy(Engine* e) { if(e->thread.joinable()) e->thread.join(); delete e; }
// Synchronous diagnostic entry point, called only by the off-screen native test.
API int oplayer_rife_probe(const char* path, const unsigned char* a, const unsigned char* b,
  unsigned char* out, int w, int h, int gpu) {
  if(w<2 || h<2 || w>320 || h>320) return -1;
  std::lock_guard<std::mutex> lock(inferenceMutex);
  NpuContext reference;reference.reference_only=true;
  auto net=model(path,gpu&1,gpu&2 ? &reference : nullptr); if(!net) return -2;
  Frame fa{0,w,h,std::vector<unsigned char>(a,a+w*h*4)},fb{1,w,h,std::vector<unsigned char>(b,b+w*h*4)},mid{};
  if(!interpolate(*net,fa,fb,mid)) return -3;
  std::memcpy(out,mid.pixels.data(),mid.pixels.size()); return 0;
}
API int oplayer_npu_vendor(const char* maker,const char* soc,const char* hardware,const char* board) {
  return npu_vendor(maker?maker:"",soc?soc:"",hardware?hardware:"",board?board:"");
}
API int oplayer_npu_driver_allowed(int vendor,const char* name,int type) {
  return npu_driver_allowed(vendor,name?name:"",type) ? 1 : 0;
}
