#include "upscale.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
UpscaleNetwork::UpscaleNetwork(const std::string &path) {
  std::ifstream f(std::filesystem::u8path(path),
                  std::ios::binary | std::ios::ate);
  if (!f || f.tellg() < 12 || f.tellg() > 262144)
    throw std::runtime_error("Invalid upscale model");
  const auto end = f.tellg();
  f.seekg(0);
  auto integer = [&]() {
    uint32_t n = 0;
    if (!f.read((char *)&n, 4))
      throw std::runtime_error("Truncated model");
    return n;
  };
  auto floats = [&](size_t count) {
    std::vector<float> v(count);
    if (!f.read((char *)v.data(), count * 4))
      throw std::runtime_error("Truncated weights");
    for (float x : v)
      if (!std::isfinite(x) || std::abs(x) > 1000)
        throw std::runtime_error("Invalid weight");
    return v;
  };
  if (integer() != 0x3153554f)
    throw std::runtime_error("Model format");
  mode = integer();
  const auto count = integer();
  if (mode > 1 || count != (mode == 0 ? 4u : 13u))
    throw std::runtime_error("Unsupported model");
  for (uint32_t i = 0; i < count; ++i) {
    UpscaleOp op{};
    op.kernel = integer();
    const auto inputs = integer();
    int channels = 0;
    if ((op.kernel != 1 && op.kernel != 3 && op.kernel != 5) || inputs < 1 ||
        inputs > 4)
      throw std::runtime_error("Invalid convolution");
    for (uint32_t k = 0; k < inputs; ++k) {
      int source = integer(), act = integer();
      if (source < 0 || source > (int)i || act > 2)
        throw std::runtime_error("Invalid graph edge");
      op.inputs.emplace_back(source, act);
      channels += source == 0 ? (mode == 0 ? 4 : 1) : 4;
    }
    const auto weights = integer();
    if (weights != (uint32_t)(4 * op.kernel * op.kernel * channels))
      throw std::runtime_error("Weight dimensions");
    op.weights = floats(weights);
    op.bias = floats(4);
    const auto alpha = integer();
    if (alpha != 0 && alpha != 4)
      throw std::runtime_error("Activation dimensions");
    op.alpha = floats(alpha);
    ops.push_back(std::move(op));
  }
  if (f.tellg() != end)
    throw std::runtime_error("Trailing model data");
}
ncnn::Mat UpscaleNetwork::input(const unsigned char *src, int w, int h,
                                bool limited, bool bt601) const {
  ncnn::Mat out(w, h, mode == 0 ? 4 : 1);
  const float r = bt601 ? .299f : .2126f, g = bt601 ? .587f : .7152f,
              b = bt601 ? .114f : .0722f;
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      const auto p = src + (y * w + x) * 4;
      const int i = y * w + x;
      if (mode == 0) {
        ((float *)out.channel(0))[i] = p[2] / 255.f;
        ((float *)out.channel(1))[i] = p[1] / 255.f;
        ((float *)out.channel(2))[i] = p[0] / 255.f;
        ((float *)out.channel(3))[i] = 1;
      } else {
        float l = (p[2] * r + p[1] * g + p[0] * b) / 255.f;
        ((float *)out.channel(0))[i] = limited ? l * 219 / 255 + 16.f / 255 : l;
      }
    }
  return out;
}
ncnn::Mat UpscaleNetwork::reference(const ncnn::Mat &input) const {
  std::vector<ncnn::Mat> values{input};
  const int w = input.w, h = input.h;
  for (const auto &op : ops) {
    int channels = 0;
    for (auto edge : op.inputs)
      channels += values[edge.first].c;
    ncnn::Mat out(w, h, 4);
    int pad = op.kernel / 2;
    for (int q = 0; q < 4; ++q) {
      float *dst = out.channel(q);
      for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
          float sum = op.bias[q];
          for (int ky = 0; ky < op.kernel; ++ky)
            for (int kx = 0; kx < op.kernel; ++kx) {
              int ci = 0;
              for (auto edge : op.inputs) {
                const auto &src = values[edge.first];
                for (int c = 0; c < src.c; ++c, ++ci) {
                  float v = ((const float *)src.channel(
                      c))[std::clamp(y + ky - pad, 0, h - 1) * w +
                          std::clamp(x + kx - pad, 0, w - 1)];
                  if (edge.second == 1)
                    v = std::max(v, 0.f);
                  if (edge.second == 2)
                    v = std::max(-v, 0.f);
                  sum +=
                      v * op.weights[((q * op.kernel + ky) * op.kernel + kx) *
                                         channels +
                                     ci];
                }
              }
            }
          dst[y * w + x] =
              !op.alpha.empty() && sum < 0 ? sum * op.alpha[q] : sum;
        }
    }
    values.push_back(out);
  }
  return values.back();
}
void UpscaleNetwork::pixels(const unsigned char *src, int w, int h,
                            const ncnn::Mat &net, unsigned char *out, int tw,
                            int th, bool limited, bool bt601) const {
  auto sample = [&](float x, float y, auto pixel) {
    int ix = (int)std::floor(x), iy = (int)std::floor(y);
    float fx = x - ix, fy = y - iy;
    return (pixel(ix, iy) * (1 - fx) + pixel(ix + 1, iy) * fx) * (1 - fy) +
           (pixel(ix, iy + 1) * (1 - fx) + pixel(ix + 1, iy + 1) * fx) * fy;
  };
  auto residual = [&](int x, int y) {
    x = std::clamp(x, 0, w * 2 - 1);
    y = std::clamp(y, 0, h * 2 - 1);
    int q = mode == 0 ? (y % 2) * 2 + x % 2 : (x % 2) * 2 + y % 2;
    return ((const float *)net.channel(q))[(y / 2) * w + x / 2];
  };
  const float coefficients[] = {bt601 ? .114f : .0722f, bt601 ? .587f : .7152f,
                                bt601 ? .299f : .2126f};
  for (int y = 0; y < th; ++y)
    for (int x = 0; x < tw; ++x) {
      float sx = (x + .5f) * w / tw - .5f, sy = (y + .5f) * h / th - .5f;
      float color[3];
      for (int c = 0; c < 3; ++c)
        color[c] = sample(sx, sy, [&](int xx, int yy) {
          return src[(std::clamp(yy, 0, h - 1) * w + std::clamp(xx, 0, w - 1)) *
                         4 +
                     c] /
                 255.f;
        });
      float delta = sample((x + .5f) * w * 2 / tw - .5f,
                           (y + .5f) * h * 2 / th - .5f, residual);
      if (mode == 1) {
        if (limited)
          delta = (delta - 16.f / 255) * 255 / 219;
        for (int c = 0; c < 3; ++c)
          delta -= color[c] * coefficients[c];
      }
      for (int c = 0; c < 3; ++c)
        out[(y * tw + x) * 4 + c] = (unsigned char)std::clamp(
            (color[c] + delta) * 255 + .5f, 0.f, 255.f);
      out[(y * tw + x) * 4 + 3] = 255;
    }
}
#ifndef __ANDROID__
std::unique_ptr<NpuGraph> compile_upscale(NpuContext &, const UpscaleNetwork &,
                                          const ncnn::Mat &,
                                          const std::string &) {
  return {};
}
#endif
