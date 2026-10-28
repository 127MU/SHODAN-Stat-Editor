// Steam %command% wrapper. No injection, Steam configuration edits or game flags.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

static unsigned long long started(HANDLE process){
 FILETIME c{},e{},k{},u{};
 return GetProcessTimes(process,&c,&e,&k,&u)?(static_cast<unsigned long long>(c.dwHighDateTime)<<32)|c.dwLowDateTime:0;
}
static std::wstring environment(const wchar_t* name){
 DWORD size=GetEnvironmentVariableW(name,nullptr,0);if(!size)return {};
 std::vector<wchar_t> value(size);GetEnvironmentVariableW(name,value.data(),size);return value.data();
}
static bool listening(int port){
 WSADATA data{};if(WSAStartup(MAKEWORD(2,2),&data))return false;
 SOCKET socket=::socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);bool ok=false;
 if(socket!=INVALID_SOCKET){
  u_long nonblocking=1;ioctlsocket(socket,FIONBIO,&nonblocking);
  sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(static_cast<u_short>(port));address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  if(connect(socket,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0)ok=true;
  else if(WSAGetLastError()==WSAEWOULDBLOCK){
   fd_set write,error;FD_ZERO(&write);FD_ZERO(&error);FD_SET(socket,&write);FD_SET(socket,&error);timeval timeout{0,500000};
   if(select(0,nullptr,&write,&error,&timeout)>0 && FD_ISSET(socket,&write) && !FD_ISSET(socket,&error)){
    int result=0,length=sizeof(result);ok=getsockopt(socket,SOL_SOCKET,SO_ERROR,reinterpret_cast<char*>(&result),&length)==0 && result==0;
   }
  }
  closesocket(socket);
 }
 WSACleanup();return ok;
}

int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
 int argc=0;LPWSTR* argv=CommandLineToArgvW(GetCommandLineW(),&argc);
 if(!argv || argc<2){if(argv)LocalFree(argv);MessageBoxW(nullptr,L"请将编辑器生成的启动选项粘贴到 Steam 游戏属性中，然后从 Steam 启动。",L"SHODAN Steam 启动桥接",MB_OK|MB_ICONINFORMATION);return 2;}
 std::wstring program=argv[1];LocalFree(argv);
 // Keep Steam's original argument quoting verbatim. Only skip our argv[0].
 const wchar_t* tail=GetCommandLineW();
 while(*tail==L' ' || *tail==L'\t')++tail;
 if(*tail==L'"'){++tail;while(*tail && *tail!=L'"')++tail;if(*tail)++tail;}
 else while(*tail && *tail!=L' ' && *tail!=L'\t')++tail;
 while(*tail==L' ' || *tail==L'\t')++tail;
 std::wstring command=tail;
 wchar_t own[32768]{};GetModuleFileNameW(nullptr,own,32768);
 std::wstring dir=own;dir.resize(dir.find_last_of(L"\\/"));
 std::wstring config=dir+L"\\steam-proxy.ini";
 int port=GetPrivateProfileIntW(L"proxy",L"port",0,config.c_str());
 DWORD pid=GetPrivateProfileIntW(L"proxy",L"pid",0,config.c_str());
 wchar_t expected[32]{};GetPrivateProfileStringW(L"proxy",L"started",L"0",expected,32,config.c_str());
 HANDLE proxy=pid?OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,pid):nullptr;
 bool active=proxy && port>0 && port<65536 && WaitForSingleObject(proxy,0)==WAIT_TIMEOUT && started(proxy)==_wcstoui64(expected,nullptr,10);
 if(proxy)CloseHandle(proxy);
 // No active editor session means ordinary Steam launch. Never leave a stale
 // proxy behind after the editor exits, and never change user/system settings.
 if(active){
  if(!listening(port)){MessageBoxW(nullptr,L"代理进程存在，但本机端口尚未就绪，游戏未启动。请在编辑器中停止变种代理后重新开启，等待就绪后再从 Steam 启动。",L"SHODAN Steam 启动桥接",MB_OK|MB_ICONWARNING);return 4;}
  std::wstring address=L"http://127.0.0.1:"+std::to_wstring(port);
  for(auto name:{L"HTTP_PROXY",L"HTTPS_PROXY",L"http_proxy",L"https_proxy"})SetEnvironmentVariableW(name,address.c_str());
  // Login does not use WarSeason data. Keep it outside the local interception
  // route, and preserve caller exclusions instead of replacing them.
  std::wstring bypass=environment(L"NO_PROXY");
  if(!bypass.empty())bypass+=L",";
  bypass+=L"localhost,127.0.0.1,::1,playfabapi.com,.playfabapi.com,playfab.com,.playfab.com";
  SetEnvironmentVariableW(L"NO_PROXY",bypass.c_str());
  SetEnvironmentVariableW(L"no_proxy",bypass.c_str());
 }
 std::vector<wchar_t> mutableCommand(command.begin(),command.end());mutableCommand.push_back(0);
 STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
 // Steam supplies the executable and working directory; preserve both.
 if(!CreateProcessW(program.c_str(),mutableCommand.data(),nullptr,nullptr,FALSE,0,nullptr,nullptr,&si,&pi)){
  std::wstring error=L"Steam 原始启动命令执行失败，Windows 错误 "+std::to_wstring(GetLastError())+L"。请检查启动选项；删除桥接启动选项可恢复普通 Steam 启动。";
  MessageBoxW(nullptr,error.c_str(),L"SHODAN Steam 启动桥接",MB_OK|MB_ICONERROR);return 3;
 }
 CloseHandle(pi.hThread);WaitForSingleObject(pi.hProcess,INFINITE);DWORD code=1;GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);return static_cast<int>(code);
}
