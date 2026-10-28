#pragma once
#include "net.h"
#include "rife_npu_blocks.h"
#include <atomic>
#include <memory>
#include <string>
#include <vector>

// The allowlist is SoC-specific, never the phone's brand/manufacturer.
int npu_vendor(std::string manufacturer, std::string soc, std::string hardware, std::string board);
bool npu_driver_allowed(int vendor, std::string name, int device_type);
struct NpuContext {
  std::atomic<int> state{0}, executions{0}; // 0 unavailable, 1 preparing, 2 invoked, 3 GPU fallback
  int vendor=0;
  bool reference_only=false;
  std::string cache;
  struct Device { const void* handle; std::string name,version; };
  std::vector<Device> devices;
};
struct NpuWeights { ncnn::Mat kernel,bias; };
struct NpuGraph {
  virtual ~NpuGraph()=default;
  virtual bool run(const ncnn::Mat&, ncnn::Mat&)=0;
};
std::shared_ptr<NpuContext> discover_npu(const std::string& directory);
std::unique_ptr<NpuGraph> compile_npu(NpuContext&,int block,const ncnn::Mat&,
  const std::vector<NpuWeights>&);
void register_npu(ncnn::Net&,NpuContext*);
