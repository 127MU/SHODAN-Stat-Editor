#ifndef RUNNER_WALLPAPER_VIDEO_H_
#define RUNNER_WALLPAPER_VIDEO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/texture_registrar.h>

#include <memory>
#include <unordered_map>

class WallpaperVideo {
 public:
  WallpaperVideo(flutter::BinaryMessenger* messenger,
                 flutter::TextureRegistrar* registrar);
  ~WallpaperVideo();
  void CloseAll();

 private:
  class Playback;
  void Close(int64_t id);

  flutter::TextureRegistrar* registrar_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::unordered_map<int64_t, std::shared_ptr<Playback>> players_;
};

#endif  // RUNNER_WALLPAPER_VIDEO_H_
