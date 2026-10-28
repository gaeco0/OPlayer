#pragma once
#include "npu.h"
#include <utility>
struct UpscaleOp {
  int kernel;
  std::vector<std::pair<int, int>> inputs;
  std::vector<float> weights, bias, alpha;
};
struct UpscaleNetwork {
  int mode = 0;
  std::vector<UpscaleOp> ops;
  explicit UpscaleNetwork(const std::string &path);
  ncnn::Mat input(const unsigned char *, int, int, bool limited = false,
                  bool bt601 = false) const;
  ncnn::Mat reference(const ncnn::Mat &) const;
  void pixels(const unsigned char *, int, int, const ncnn::Mat &,
              unsigned char *, int, int, bool limited = false,
              bool bt601 = false) const;
};
std::unique_ptr<NpuGraph> compile_upscale(NpuContext &, const UpscaleNetwork &,
                                          const ncnn::Mat &,
                                          const std::string &);
