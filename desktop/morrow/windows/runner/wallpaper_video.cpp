#include "wallpaper_video.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <mutex>
#include <thread>
#include <vector>

#include "wallpaper_scene.h"

namespace {
using Clock = std::chrono::steady_clock;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr DWORD kVideo =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr UINT32 kMaxTextureSide = 1280;
constexpr LONGLONG kFrameInterval = 320000;  // About 30 FPS in 100 ns units.
std::atomic_uint64_t scene_sequence{0};

using Frame = WallpaperFrame;

// Keep the immutable frame alive while Flutter uploads it on the raster thread.
struct FrameLease {
  explicit FrameLease(std::shared_ptr<const Frame> frame)
      : frame(std::move(frame)),
        buffer{
            this->frame->rgba.data(), this->frame->width, this->frame->height,
            [](void* lease) { delete static_cast<FrameLease*>(lease); }, this} {
  }
  std::shared_ptr<const Frame> frame;
  FlutterDesktopPixelBuffer buffer;
};

bool MediaFoundationAvailable() {
  for (const wchar_t* name : {L"mfplat.dll", L"mfreadwrite.dll"}) {
    const HMODULE module =
        LoadLibraryExW(name, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return false;
    FreeLibrary(module);
  }
  return true;
}

std::shared_ptr<Frame> ReadFrame(IMFSample* sample, IMFSourceReader* reader) {
  ComPtr<IMFMediaType> type;
  ComPtr<IMFMediaBuffer> buffer;
  UINT32 width = 0, height = 0, stored_stride = 0;
  if (FAILED(reader->GetCurrentMediaType(kVideo, &type)) ||
      FAILED(
          MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height)) ||
      !width || !height || width > 8192 || height > 8192 ||
      FAILED(sample->ConvertToContiguousBuffer(&buffer))) {
    return nullptr;
  }
  LONG stride = 0;
  if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stored_stride))) {
    stride = static_cast<LONG>(stored_stride);
  } else if (FAILED(MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1,
                                                   width, &stride))) {
    return nullptr;
  }
  const auto side = std::max({width, height, kMaxTextureSide});
  auto frame = std::make_shared<Frame>();
  frame->width = std::max(1u, width * kMaxTextureSide / side);
  frame->height = std::max(1u, height * kMaxTextureSide / side);
  frame->rgba.resize(static_cast<size_t>(frame->width) * frame->height * 4);

  BYTE* bytes = nullptr;
  DWORD length = 0;
  if (FAILED(buffer->Lock(&bytes, nullptr, &length))) return nullptr;
  const auto pitch =
      static_cast<size_t>(std::abs(static_cast<int64_t>(stride)));
  if (pitch < width * 4 || pitch * (height - 1) + width * 4 > length) {
    buffer->Unlock();
    return nullptr;
  }
  for (UINT32 y = 0; y < frame->height; ++y) {
    const auto source_y = y * height / frame->height;
    const BYTE* row =
        bytes + pitch * (stride < 0 ? height - 1 - source_y : source_y);
    auto* out = frame->rgba.data() + static_cast<size_t>(y) * frame->width * 4;
    for (UINT32 x = 0; x < frame->width; ++x, out += 4) {
      const BYTE* pixel = row + (x * width / frame->width) * 4;
      out[0] = pixel[2];
      out[1] = pixel[1];
      out[2] = pixel[0];
      out[3] = 255;
    }
  }
  buffer->Unlock();
  return frame;
}
}  // namespace

class WallpaperVideo::Playback {
 public:
  explicit Playback(flutter::TextureRegistrar* registrar)
      : registrar(registrar),
        texture(flutter::PixelBufferTexture([this](size_t, size_t) {
          std::lock_guard lock(mutex);
          return frame ? &(new FrameLease(frame))->buffer : nullptr;
        })) {}

  void Run(const std::filesystem::path& path) {
    const auto apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool ok = false;
    if (SUCCEEDED(apartment)) {
      if (MediaFoundationAvailable() && SUCCEEDED(MFStartup(MF_VERSION))) {
        ok = Decode(path);
        MFShutdown();
      }
      CoUninitialize();
    }
    std::lock_guard lock(mutex);
    failed = !ok && !stopped;
  }

  void RunScene(const std::filesystem::path& engine,
                const std::filesystem::path& project) {
    const auto apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool launched = false;
    const auto name = L"SHODAN-Scene-" +
                      std::to_wstring(GetCurrentProcessId()) + L"-" +
                      std::to_wstring(++scene_sequence);
    if (SUCCEEDED(apartment)) {
      {
        std::lock_guard lock(mutex);
        if (!stopped) {
          scene_engine = engine;
          scene_name = name;
          launched =
              OpenWallpaperScene(engine, project, scene_name, scene_process);
          if (!launched) scene_name.clear();
        }
      }
      if (launched) {
        CaptureWallpaperScene(
            name,
            [this] {
              auto tick = Clock::now();
              return Wait(tick);
            },
            [this](std::shared_ptr<Frame> next) { Publish(std::move(next)); });
        std::lock_guard lock(mutex);
        failed = !stopped;
        CloseScene();
      }
      CoUninitialize();
    }
    if (!launched) {
      std::lock_guard lock(mutex);
      failed = !stopped;
    }
  }

  EncodableValue Status() {
    std::lock_guard lock(mutex);
    return EncodableValue(EncodableMap{
        {EncodableValue("failed"), EncodableValue(failed)},
        {EncodableValue("width"),
         EncodableValue(frame ? static_cast<int>(frame->width) : 0)},
        {EncodableValue("height"),
         EncodableValue(frame ? static_cast<int>(frame->height) : 0)},
    });
  }

  void SetVisible(bool visible) {
    std::lock_guard lock(mutex);
    paused = !visible;
    wake.notify_all();
  }

  void Stop() {
    std::lock_guard lock(mutex);
    stopped = true;
    wake.notify_all();
    CloseScene();
  }

  flutter::TextureRegistrar* registrar;
  flutter::TextureVariant texture;
  int64_t id = -1;

 private:
  void CloseScene() {
    if (!scene_name.empty()) {
      CloseWallpaperScene(scene_engine, scene_name, scene_process);
      scene_name.clear();
    }
  }

  void Publish(std::shared_ptr<Frame> next) {
    std::lock_guard lock(mutex);
    if (stopped) return;
    frame = std::move(next);
    registrar->MarkTextureFrameAvailable(id);
  }

  bool Wait(Clock::time_point& start, Clock::duration offset = {}) {
    std::unique_lock lock(mutex);
    while (!stopped) {
      if (paused) {
        const auto pause_start = Clock::now();
        wake.wait(lock, [this] { return !paused || stopped; });
        start += Clock::now() - pause_start;
      } else if (!wake.wait_until(lock, start + offset,
                                  [this] { return paused || stopped; })) {
        return true;
      }
    }
    return false;
  }

  static Clock::duration FrameTime(LONGLONG ticks) {
    return std::chrono::duration_cast<Clock::duration>(
        std::chrono::duration<double>(
            std::clamp(static_cast<double>(ticks) / 10000000.0, 0.0, 86400.0)));
  }

  bool Decode(const std::filesystem::path& path) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(path, error)) return false;
    ComPtr<IMFAttributes> attributes;
    ComPtr<IMFSourceReader> reader;
    ComPtr<IMFMediaType> rgb;
    if (FAILED(MFCreateAttributes(&attributes, 1)) ||
        FAILED(attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                     TRUE)) ||
        FAILED(MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(),
                                           &reader)) ||
        FAILED(reader->SetStreamSelection(
            static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE)) ||
        FAILED(reader->SetStreamSelection(kVideo, TRUE)) ||
        FAILED(MFCreateMediaType(&rgb)) ||
        FAILED(rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)) ||
        FAILED(rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32)) ||
        FAILED(reader->SetCurrentMediaType(kVideo, nullptr, rgb.Get()))) {
      return false;
    }

    auto start = Clock::now();
    LONGLONG first = -1, last = -kFrameInterval;
    auto last_end = Clock::duration::zero();
    while (Wait(start)) {
      ComPtr<IMFSample> sample;
      DWORD flags = 0;
      LONGLONG timestamp = 0;
      if (FAILED(reader->ReadSample(kVideo, 0, nullptr, &flags, &timestamp,
                                    &sample)) ||
          (flags & MF_SOURCE_READERF_ERROR))
        return false;
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        if (first < 0) return false;
        if (!Wait(start, last_end)) return true;
        PROPVARIANT position{};
        position.vt = VT_I8;
        if (FAILED(reader->SetCurrentPosition(GUID_NULL, position)))
          return false;
        first = -1;
        last = -kFrameInterval;
        continue;
      }
      if (!sample) continue;
      timestamp = std::max<LONGLONG>(0, timestamp);
      if (first < 0) {
        first = timestamp;
        start = Clock::now();
      }
      const auto elapsed = std::max<LONGLONG>(0, timestamp - first);
      LONGLONG duration = 0;
      sample->GetSampleDuration(&duration);
      last_end = FrameTime(elapsed) + FrameTime(duration);
      if (last >= 0 && elapsed - last < kFrameInterval) continue;
      auto next = ReadFrame(sample.Get(), reader.Get());
      if (!next) return false;
      if (!Wait(start, FrameTime(elapsed))) return true;
      Publish(std::move(next));
      last = elapsed;
    }
    return true;
  }

  std::mutex mutex;
  std::condition_variable wake;
  std::shared_ptr<Frame> frame;
  std::filesystem::path scene_engine;
  std::wstring scene_name;
  SceneProcess scene_process;
  bool paused = false, stopped = false, failed = false;
};

WallpaperVideo::WallpaperVideo(flutter::BinaryMessenger* messenger,
                               flutter::TextureRegistrar* registrar)
    : registrar_(registrar),
      channel_(messenger, "shodan/wallpaper-video",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (!args) {
      result->Error("arguments");
      return;
    }
    const bool scene = call.method_name() == "openScene";
    if (call.method_name() == "open" || scene) {
      const auto entry = args->find(EncodableValue("path"));
      const auto* file = entry == args->end()
                             ? nullptr
                             : std::get_if<std::string>(&entry->second);
      if (!file || file->empty()) {
        result->Error("file");
        return;
      }
      const auto path = std::filesystem::u8path(*file);
      std::filesystem::path engine;
      if (scene) {
        const auto engine_entry = args->find(EncodableValue("engine"));
        const auto* directory =
            engine_entry == args->end()
                ? nullptr
                : std::get_if<std::string>(&engine_entry->second);
        if (!directory || directory->empty()) {
          result->Error("engine");
          return;
        }
        engine = std::filesystem::u8path(*directory);
      }
      auto player = std::make_shared<Playback>(registrar_);
      player->id = registrar_->RegisterTexture(&player->texture);
      if (player->id < 0) {
        result->Error("texture");
        return;
      }
      players_.emplace(player->id, player);
      try {
        std::thread([player, path, engine, scene] {
          if (scene)
            player->RunScene(engine, path);
          else
            player->Run(path);
        }).detach();
      } catch (const std::system_error&) {
        Close(player->id);
        result->Error("worker");
        return;
      }
      result->Success(EncodableValue(player->id));
      return;
    }

    const auto entry = args->find(EncodableValue("id"));
    if (entry == args->end() ||
        (!std::holds_alternative<int32_t>(entry->second) &&
         !std::holds_alternative<int64_t>(entry->second))) {
      result->Error("arguments");
      return;
    }
    const auto id = entry->second.LongValue();
    const auto player = players_.find(id);
    if (player == players_.end()) {
      result->Error("player");
    } else if (call.method_name() == "status") {
      result->Success(player->second->Status());
    } else if (call.method_name() == "visible") {
      const auto value = args->find(EncodableValue("value"));
      const auto* visible =
          value == args->end() ? nullptr : std::get_if<bool>(&value->second);
      if (visible) player->second->SetVisible(*visible);
      result->Success();
    } else if (call.method_name() == "close") {
      Close(id);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

void WallpaperVideo::Close(int64_t id) {
  const auto player = players_.at(id);
  players_.erase(id);
  player->Stop();
  // The decoder can unwind independently. Keep the texture callback's owner
  // until Flutter has removed the texture on its raster thread.
  registrar_->UnregisterTexture(id, [player] {});
}

WallpaperVideo::~WallpaperVideo() {
  channel_.SetMethodCallHandler(nullptr);
  CloseAll();
}

void WallpaperVideo::CloseAll() {
  while (!players_.empty()) Close(players_.begin()->first);
}
