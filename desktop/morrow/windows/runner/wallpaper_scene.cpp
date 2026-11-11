#include "wallpaper_scene.h"

#include <tlhelp32.h>

#include <chrono>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
constexpr int kWidth = 960;
constexpr int kHeight = 540;

std::filesystem::path EngineExecutable(const std::filesystem::path& engine) {
  // Send commands to the running bitness when this installation is active.
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot != INVALID_HANDLE_VALUE) {
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    std::filesystem::path running;
    for (BOOL found = Process32FirstW(snapshot, &entry); found;
         found = Process32NextW(snapshot, &entry)) {
      if (_wcsicmp(entry.szExeFile, L"wallpaper64.exe") != 0 &&
          _wcsicmp(entry.szExeFile, L"wallpaper32.exe") != 0)
        continue;
      const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                         FALSE, entry.th32ProcessID);
      if (!process) continue;
      wchar_t file[32768];
      DWORD size = ARRAYSIZE(file);
      const BOOL queried = QueryFullProcessImageNameW(process, 0, file, &size);
      CloseHandle(process);
      if (!queried) continue;
      const std::filesystem::path candidate(file);
      if (_wcsicmp(candidate.parent_path().c_str(), engine.c_str()) == 0) {
        running = candidate;
        break;
      }
    }
    CloseHandle(snapshot);
    if (!running.empty()) return running;
  }
  std::error_code error;
  const auto preferred = engine / L"wallpaper64.exe";
  return std::filesystem::is_regular_file(preferred, error)
             ? preferred
             : engine / L"wallpaper32.exe";
}

bool Command(const std::filesystem::path& engine, const std::wstring& args,
             SceneProcess* owned = nullptr) {
  const auto exe = EngineExecutable(engine);
  std::wstring command = L"\"" + exe.native() + L"\" -control " + args;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};
  const DWORD flags = CREATE_NO_WINDOW | (owned ? CREATE_SUSPENDED : 0);
  if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE,
                      flags, nullptr, engine.c_str(), &startup, &process)) {
    return false;
  }
  if (owned) {
    // Only the process created for this pop-out is eligible for cleanup.
    // An already running Wallpaper Engine instance stays outside the job.
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (job && (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                         &limits, sizeof(limits)) ||
                !AssignProcessToJobObject(job, process.hProcess))) {
      CloseHandle(job);
      job = nullptr;
    }
    if (ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
      TerminateProcess(process.hProcess, 1);
      if (job) CloseHandle(job);
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
      return false;
    }
    owned->job = job;
    owned->process = process.hProcess;
  } else {
    CloseHandle(process.hProcess);
  }
  CloseHandle(process.hThread);
  return true;
}

class WindowBitmap {
 public:
  ~WindowBitmap() {
    if (previous_) SelectObject(dc_, previous_);
    if (bitmap_) DeleteObject(bitmap_);
    if (dc_) DeleteDC(dc_);
  }

  bool Create(int width, int height) {
    width_ = width;
    height_ = height;
    dc_ = CreateCompatibleDC(nullptr);
    if (!dc_) return false;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void* pixels = nullptr;
    bitmap_ = CreateDIBSection(dc_, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap_ || !pixels) return false;
    previous_ = SelectObject(dc_, bitmap_);
    if (!previous_ || previous_ == HGDI_ERROR) {
      previous_ = nullptr;
      return false;
    }
    pixels_ = static_cast<const uint8_t*>(pixels);
    return true;
  }

  std::shared_ptr<WallpaperFrame> Capture(HWND window, bool require_color) {
    // PW_RENDERFULLCONTENT also renders the composited surface of a D3D
    // pop-out. PW_CLIENTONLY excludes its non-client frame.
    constexpr UINT kRenderFullContent = 2;
    if (!PrintWindow(window, dc_, PW_CLIENTONLY | kRenderFullContent))
      return nullptr;
    GdiFlush();
    auto frame = std::make_shared<WallpaperFrame>();
    frame->width = static_cast<uint32_t>(width_);
    frame->height = static_cast<uint32_t>(height_);
    frame->rgba.resize(static_cast<size_t>(width_) * height_ * 4);
    bool has_color = false;
    auto* out = frame->rgba.data();
    const auto* in = pixels_;
    for (size_t offset = 0; offset < frame->rgba.size();
         offset += 4, in += 4, out += 4) {
      out[0] = in[2];
      out[1] = in[1];
      out[2] = in[0];
      out[3] = 255;
      has_color |= (in[0] | in[1] | in[2]) != 0;
    }
    return require_color && !has_color ? nullptr : frame;
  }

 private:
  HDC dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ previous_ = nullptr;
  const uint8_t* pixels_ = nullptr;
  int width_ = 0, height_ = 0;
};
}  // namespace

bool OpenWallpaperScene(const std::filesystem::path& engine,
                        const std::filesystem::path& project,
                        const std::wstring& name, SceneProcess& process) {
  std::error_code error;
  if (project.filename() != L"project.json" ||
      !std::filesystem::is_regular_file(project, error))
    return false;
  return Command(engine,
                 L"openWallpaper -file \"" + project.native() +
                     L"\" -playInWindow \"" + name + L"\" -width " +
                     std::to_wstring(kWidth) + L" -height " +
                     std::to_wstring(kHeight) + L" -x -1600 -y 20 -borderless",
                 &process);
}

void CloseWallpaperScene(const std::filesystem::path& engine,
                         const std::wstring& name, SceneProcess& process) {
  if (const HWND window = FindWindowW(nullptr, name.c_str())) {
    PostMessageW(window, WM_CLOSE, 0, 0);
  } else if (!process.job ||
             WaitForSingleObject(process.process, 0) == WAIT_OBJECT_0) {
    // The command may have forwarded the launch to an existing engine.
    Command(engine, L"closeWallpaper -location \"" + name + L"\"");
  }
  if (process.job) CloseHandle(process.job);
  if (process.process) CloseHandle(process.process);
  process = {};
}

void CaptureWallpaperScene(
    const std::wstring& name, const std::function<bool()>& wait_for_frame,
    const std::function<void(std::shared_ptr<WallpaperFrame>)>& publish) {
  HWND window = nullptr;
  const auto deadline = Clock::now() + 10s;
  while (!window && Clock::now() < deadline) {
    if (!wait_for_frame()) return;
    window = FindWindowW(nullptr, name.c_str());
    if (!window) std::this_thread::sleep_for(50ms);
  }
  if (!window) return;
  DWORD affinity = WDA_NONE;
  if (GetWindowDisplayAffinity(window, &affinity) && affinity != WDA_NONE)
    return;

  const auto style = GetWindowLongPtrW(window, GWL_EXSTYLE);
  SetWindowLongPtrW(window, GWL_EXSTYLE,
                    (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
  SetWindowPos(window, HWND_BOTTOM,
               GetSystemMetrics(SM_XVIRTUALSCREEN) - kWidth - 100,
               GetSystemMetrics(SM_YVIRTUALSCREEN) - kHeight - 100, kWidth,
               kHeight, SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);

  RECT rect{};
  if (!GetClientRect(window, &rect) || rect.right <= 0 || rect.bottom <= 0 ||
      rect.right > 1920 || rect.bottom > 1200)
    return;
  WindowBitmap bitmap;
  if (!bitmap.Create(rect.right, rect.bottom)) return;

  const auto first_frame_deadline = Clock::now() + 8s;
  bool delivered = false;
  while (wait_for_frame() && IsWindow(window) && !IsHungAppWindow(window)) {
    const auto tick = Clock::now();
    if (auto frame = bitmap.Capture(window, !delivered)) {
      publish(std::move(frame));
      delivered = true;
    } else if (delivered || tick >= first_frame_deadline) {
      return;
    }
    std::this_thread::sleep_until(tick + 40ms);
  }
}
