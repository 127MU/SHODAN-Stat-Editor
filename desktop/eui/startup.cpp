#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
int eui_app_run();
namespace {
std::string graphicsError;
void onGraphicsError(int code,const char* text){graphicsError=std::to_string(code)+": "+(text?text:"");std::fprintf(stderr,"GLFW %s\n",graphicsError.c_str());std::fflush(stderr);}
}
int main(){
 glfwSetErrorCallback(onGraphicsError);
 std::string error;int code=1;
 try{code=eui_app_run();if(code!=0)error="图形界面初始化失败。需要可用的 OpenGL 3.3 驱动。\n"+graphicsError;}
 catch(const std::exception& e){error=e.what();}catch(...){error="界面发生未知启动错误。";}
 if(!error.empty()){
  std::fprintf(stderr,"Startup failure: %s\n",error.c_str());std::fflush(stderr);
  if(!std::getenv("SHODAN_EUI_QA")){
   int size=MultiByteToWideChar(CP_UTF8,0,error.data(),int(error.size()),nullptr,0);std::wstring message(size,L' ');MultiByteToWideChar(CP_UTF8,0,error.data(),int(error.size()),message.data(),size);
   message+=L"\n启动日志位于编辑器用户目录的 Logs 文件夹。";MessageBoxW(nullptr,message.c_str(),L"SHODAN 启动失败",MB_OK|MB_ICONERROR);
  }if(!code)code=1;
 }return code;
}
