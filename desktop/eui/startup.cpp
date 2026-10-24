#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <vector>
#include <string>
int eui_app_run();
namespace {
std::string graphicsError;
void initializeStartupLog(){
 HANDLE current=GetStdHandle(STD_ERROR_HANDLE);
 if(current&&current!=INVALID_HANDLE_VALUE&&GetFileType(current)!=FILE_TYPE_UNKNOWN)return;
 wchar_t buffer[32768];std::vector<std::filesystem::path> folders;
 DWORD length=GetEnvironmentVariableW(L"SHODAN_PROFILE",buffer,32768);
 if(length&&length<32768)folders.push_back(std::filesystem::path(buffer)/L"Logs");
 length=GetEnvironmentVariableW(L"LOCALAPPDATA",buffer,32768);
 if(length&&length<32768)folders.push_back(std::filesystem::path(buffer)/L"SHODAN"/L"StatEditor"/L"Logs");
 length=GetModuleFileNameW(nullptr,buffer,32768);
 if(length&&length<32768)folders.push_back(std::filesystem::path(buffer).parent_path()/L".SHODAN"/L"Profile"/L"Logs");
 for(const auto& folder:folders){std::error_code error;std::filesystem::create_directories(folder,error);if(error)continue;
  auto path=folder/(L"startup-ui-"+std::to_wstring(GetCurrentProcessId())+L".log");
  if(_wfreopen(path.c_str(),L"a",stderr))return;
 }
}
void onGraphicsError(int code,const char* text){graphicsError=std::to_string(code)+": "+(text?text:"");std::fprintf(stderr,"GLFW %s\n",graphicsError.c_str());std::fflush(stderr);}
}
int main(){
 initializeStartupLog();
 glfwSetErrorCallback(onGraphicsError);
 std::string error;int code=1;
 std::fprintf(stderr,"[startup] Starting SHODAN graphics runtime\n");std::fflush(stderr);
 try{code=eui_app_run();std::fprintf(stderr,"[startup] UI loop exited with code %d\n",code);std::fflush(stderr);if(code!=0)error="图形界面初始化失败。需要可用的 OpenGL 3.3 驱动。\n"+graphicsError;}
 catch(const std::exception& e){error=e.what();}catch(...){error="界面发生未知启动错误。";}
 if(!error.empty()){
  std::fprintf(stderr,"Startup failure: %s\n",error.c_str());std::fflush(stderr);
  if(!std::getenv("SHODAN_EUI_QA")){
   int size=MultiByteToWideChar(CP_UTF8,0,error.data(),int(error.size()),nullptr,0);std::wstring message(size,L' ');MultiByteToWideChar(CP_UTF8,0,error.data(),int(error.size()),message.data(),size);
   message+=L"\n启动日志位于编辑器用户目录的 Logs 文件夹。";MessageBoxW(nullptr,message.c_str(),L"SHODAN 启动失败",MB_OK|MB_ICONERROR);
  }if(!code)code=1;
 }return code;
}
