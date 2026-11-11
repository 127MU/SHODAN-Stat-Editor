#ifndef RUNNER_WALLPAPER_SCENE_H_
#define RUNNER_WALLPAPER_SCENE_H_

#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <vector>

struct WallpaperFrame {
  uint32_t width, height;
  std::vector<uint8_t> rgba;
};

struct SceneProcess {
  HANDLE job = nullptr;
  HANDLE process = nullptr;
};

// Each scene owns a uniquely named Wallpaper Engine pop-out.
bool OpenWallpaperScene(const std::filesystem::path& engine,
                        const std::filesystem::path& project,
                        const std::wstring& name, SceneProcess& process);
void CloseWallpaperScene(const std::filesystem::path& engine,
                         const std::wstring& name, SceneProcess& process);
void CaptureWallpaperScene(
    const std::wstring& name, const std::function<bool()>& wait_for_frame,
    const std::function<void(std::shared_ptr<WallpaperFrame>)>& publish);

#endif  // RUNNER_WALLPAPER_SCENE_H_
