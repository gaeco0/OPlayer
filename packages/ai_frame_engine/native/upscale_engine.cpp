#include "mpv/client.h"
#include "upscale.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <filesystem>
#include <mutex>
#include <thread>
#ifdef _WIN32
#define API extern "C" __declspec(dllexport)
#else
#define API extern "C" __attribute__((visibility("default")))
#endif
using UClock = std::chrono::steady_clock;
using UGet = int (*)(mpv_handle *, const char *, mpv_format, void *);
using UCommand = int (*)(mpv_handle *, const char **, mpv_node *);
using UFree = void (*)(mpv_node *);
struct UFrame {
  double pts = 0;
  std::vector<unsigned char> pixels;
};
struct UpscaleEngine {
  mpv_handle *mpv;
  UGet get;
  UCommand command;
  UFree freeNode;
  std::atomic<bool> stop{false}, finished{false}, paused{false};
  std::atomic<int> state{0}, error{0};
  std::atomic<double> ms{0};
  std::mutex mutex;
  std::thread thread;
  std::deque<UFrame> frames;
  int w, h;
  double pts = 0;
  UClock::time_point captured = UClock::now();
  std::string text(const char *key) {
    mpv_node n{};
    std::string s;
    if (get(mpv, key, MPV_FORMAT_NODE, &n) >= 0) {
      if (n.format == MPV_FORMAT_STRING)
        s = n.u.string;
      freeNode(&n);
    }
    return s;
  }
  bool capture(std::vector<unsigned char> &pixels, int &w, int &h) {
    mpv_node n{};
    const char *args[] = {"screenshot-raw", "video", nullptr};
    if (command(mpv, args, &n) < 0)
      return false;
    mpv_byte_array *data = nullptr;
    int stride = 0;
    bool format = false;
    w = h = 0;
    if (n.format == MPV_FORMAT_NODE_MAP) {
      auto l = n.u.list;
      for (int i = 0; i < l->num; ++i) {
        auto &v = l->values[i];
        const auto key = l->keys[i];
        if (v.format == MPV_FORMAT_INT64) {
          if (!strcmp(key, "w"))
            w = (int)v.u.int64;
          if (!strcmp(key, "h"))
            h = (int)v.u.int64;
          if (!strcmp(key, "stride"))
            stride = (int)v.u.int64;
        }
        if (!strcmp(key, "data") && v.format == MPV_FORMAT_BYTE_ARRAY)
          data = v.u.ba;
        if (!strcmp(key, "format") && v.format == MPV_FORMAT_STRING)
          format = !strcmp(v.u.string, "bgra") || !strcmp(v.u.string, "bgr0");
      }
    }
    const bool ok = format && w > 0 && h > 0 && w <= 1920 && h <= 1920 &&
                    (int64_t)w * h <= 2073600 && stride >= w * 4 && data &&
                    data->size >= (size_t)stride * h;
    if (ok) {
      pixels.resize(w * h * 4);
      for (int y = 0; y < h; ++y)
        memcpy(pixels.data() + y * w * 4,
               (unsigned char *)data->data + y * stride, w * 4);
    }
    freeNode(&n);
    return ok;
  }
};
static void run_upscale(UpscaleEngine &e, std::string path) {
  struct Done {
    UpscaleEngine &e;
    ~Done() { e.finished = true; }
  } done{e};
  try {
    auto context =
        discover_npu(std::filesystem::u8path(path).parent_path().u8string());
    if (!context || context->state != 1) {
      e.error = 1;
      e.state = 2;
      return;
    }
    UpscaleNetwork network(path);
    std::unique_ptr<NpuGraph> graph;
    int sw = 0, sh = 0, slow = 0, generated = 0, failures = 0;
    double last = -1, fps = 24;
    e.get(e.mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps);
    if (!std::isfinite(fps) || fps <= 0)
      fps = 24;
    if (fps > 60) {
      e.error = 2;
      e.state = 2;
      return;
    }
    while (!e.stop) {
      int paused = 0, caching = 0;
      e.get(e.mpv, "pause", MPV_FORMAT_FLAG, &paused);
      e.get(e.mpv, "paused-for-cache", MPV_FORMAT_FLAG, &caching);
      e.paused = paused || caching;
      double pts = 0, speed = 1;
      e.get(e.mpv, "speed", MPV_FORMAT_DOUBLE, &speed);
      if (std::abs(speed - 1) > .001) {
        e.error = 2;
        break;
      }
      if (e.get(e.mpv, "time-pos", MPV_FORMAT_DOUBLE, &pts) < 0 ||
          !std::isfinite(pts) || std::abs(pts - last) < .0001) {
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
        continue;
      }
      const auto before = UClock::now();
      std::vector<unsigned char> pixels;
      int w, h;
      if (!e.capture(pixels, w, h)) {
        if (++failures > 30) {
          e.error = 3;
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        continue;
      }
      failures = 0;
      const auto gamma = e.text("video-params/gamma");
      if (gamma == "pq" || gamma == "hlg") {
        e.error = 2;
        break;
      }
      const auto levels = e.text("video-params/colorlevels"),
                 matrix = e.text("video-params/colormatrix");
      const bool limited = levels == "limited" || levels == "tv",
                 bt601 = matrix == "bt.601";
      const auto input = network.input(pixels.data(), w, h, limited, bt601);
      bool warming = false;
      if (!graph || w != sw || h != sh) {
        graph = compile_upscale(
            *context, network, input,
            std::filesystem::u8path(path).filename().u8string());
        sw = w;
        sh = h;
        warming = true;
        generated = slow = 0;
        std::lock_guard<std::mutex> lock(e.mutex);
        e.frames.clear();
        e.state = 0;
      }
      if (!graph) {
        e.error = 1;
        break;
      }
      ncnn::Mat output;
      if (!graph->run(input, output)) {
        e.error = 1;
        break;
      }
      ++context->executions;
      context->state = 2;
      UFrame frame{pts, std::vector<unsigned char>((size_t)e.w * e.h * 4)};
      network.pixels(pixels.data(), w, h, output, frame.pixels.data(), e.w, e.h,
                     limited, bt601);
      const double ms =
          std::chrono::duration<double, std::milli>(UClock::now() - before)
              .count();
      e.ms = ms;
      if (!warming && ++generated > 4) {
        if (ms > 900. / fps)
          ++slow;
        else
          slow = std::max(0, slow - 1);
        if (slow >= 6) {
          e.error = 4;
          break;
        }
      }
      {
        std::lock_guard<std::mutex> lock(e.mutex);
        if (last >= 0 && (pts < last || pts - last > .25)) {
          e.frames.clear();
          e.state = 0;
        }
        e.frames.push_back(std::move(frame));
        while (e.frames.size() > 8)
          e.frames.pop_front();
        e.pts = pts;
        e.captured = before;
        if (e.paused || (e.frames.size() > 1 && pts - e.frames.front().pts >= .10))
          e.state = 1;
      }
      last = pts;
    }
  } catch (...) {
    e.error = 1;
  }
  e.state = e.error ? 2 : 3;
}
API UpscaleEngine *oplayer_upscale_start(const char *path, void *mpv, void *get,
                                         void *command, void *freeNode, int w,
                                         int h) {
  if (!path || !mpv || !get || !command || !freeNode || w < 2 || h < 2 ||
      w > 4096 || h > 4096 || (int64_t)w * h > 8294400)
    return nullptr;
  try {
    auto e = std::make_unique<UpscaleEngine>();
    e->mpv = (mpv_handle *)mpv;
    e->get = (UGet)get;
    e->command = (UCommand)command;
    e->freeNode = (UFree)freeNode;
    e->w = w;
    e->h = h;
    e->thread = std::thread(run_upscale, std::ref(*e), std::string(path));
    return e.release();
  } catch (...) {
    return nullptr;
  }
}
API int oplayer_upscale_poll(UpscaleEngine *e, unsigned char *pixels, int *info,
                             double *timing, int blend) {
  info[0] = e->state;
  info[1] = e->error;
  info[2] = e->w;
  info[3] = e->h;
  info[4] = e->paused ? 1 : 0;
  timing[0] = e->ms;
  if (e->state != 1)
    return 0;
  std::lock_guard<std::mutex> lock(e->mutex);
  const double elapsed = e->paused ? 0
                                   : std::clamp(std::chrono::duration<double>(
                                                    UClock::now() - e->captured)
                                                    .count(),
                                                0., .1);
  const double target = e->paused ? e->pts : e->pts + elapsed - .1;
  while (e->frames.size() > 1 && e->frames[1].pts <= target)
    e->frames.pop_front();
  if (e->frames.empty() || e->frames.front().pts > target)
    return 0;
  const auto &a = e->frames.front();
  if (target - a.pts > .15)
    return -1;
  timing[1] = a.pts;
  if (blend && e->frames.size() > 1) {
    const auto &b = e->frames[1];
    const auto alpha = (unsigned)std::clamp(
        (target - a.pts) / (b.pts - a.pts) * 256, 0., 256.);
    for (size_t i = 0; i < a.pixels.size(); ++i)
      pixels[i] =
          (a.pixels[i] * (256 - alpha) + b.pixels[i] * alpha + 128) >> 8;
    timing[1] = target;
  } else
    memcpy(pixels, a.pixels.data(), a.pixels.size());
  return 1;
}
API void oplayer_upscale_stop(UpscaleEngine *e) { e->stop = true; }
API int oplayer_upscale_finished(UpscaleEngine *e) {
  return e->finished ? 1 : 0;
}
API void oplayer_upscale_destroy(UpscaleEngine *e) {
  if (e->thread.joinable())
    e->thread.join();
  delete e;
}
API int oplayer_upscale_reference(const char *path, const unsigned char *in,
                                  unsigned char *out, int w, int h) {
  if (!path || !in || !out || w < 1 || h < 1 || w > 64 || h > 64)
    return -1;
  try {
    UpscaleNetwork network(path);
    auto value = network.input(in, w, h);
    auto result = network.reference(value);
    network.pixels(in, w, h, result, out, w * 2, h * 2);
    return 0;
  } catch (...) {
    return -2;
  }
}
