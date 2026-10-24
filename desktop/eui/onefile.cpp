// Single-file distribution. The immutable payload is verified, expanded into
// the current user's versioned cache, and launched without administrator rights.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fdi.h>
#include <bcrypt.h>
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs=std::filesystem;
static fs::path cache;
static std::string resource(int id){
 auto r=FindResourceW(nullptr,MAKEINTRESOURCEW(id),RT_RCDATA);
 if(!r)throw std::runtime_error("Missing embedded payload");
 auto h=LoadResource(nullptr,r);return {static_cast<const char*>(LockResource(h)),SizeofResource(nullptr,r)};
}
static std::wstring wide(const std::string& s){
 int n=MultiByteToWideChar(CP_UTF8,0,s.data(),int(s.size()),nullptr,0);
 std::wstring r(n,L' ');MultiByteToWideChar(CP_UTF8,0,s.data(),int(s.size()),r.data(),n);return r;
}

static fs::path environmentPath(const wchar_t* name){
 wchar_t value[32768];DWORD n=GetEnvironmentVariableW(name,value,32768);
 return n>0&&n<32768?fs::path(value):fs::path{};
}
static bool directories(const fs::path& path,DWORD& error){
 fs::path current;
 for(const auto& part:path){
  current/=part;
  if(current==path.root_name()||current==path.root_path())continue;
  DWORD present=GetFileAttributesW(current.c_str());
  if(present!=INVALID_FILE_ATTRIBUTES&&(present&FILE_ATTRIBUTE_DIRECTORY))continue;
  if(CreateDirectoryW(current.c_str(),nullptr))continue;
  error=GetLastError();DWORD attributes=GetFileAttributesW(current.c_str());
  if(error!=ERROR_ALREADY_EXISTS||attributes==INVALID_FILE_ATTRIBUTES||!(attributes&FILE_ATTRIBUTE_DIRECTORY))return false;
 }
 error=0;return true;
}
static bool writable(const fs::path& path,DWORD& error){
 if(!directories(path,error))return false;
 auto probe=path/(L".shodan-write-test-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
 auto h=CreateFileW(probe.c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,CREATE_NEW,
   FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,nullptr);
 if(h==INVALID_HANDLE_VALUE){error=GetLastError();return false;}
 DWORD written=0;char byte=0;BOOL ok=WriteFile(h,&byte,1,&written,nullptr);
 error=ok?0:GetLastError();CloseHandle(h);return ok&&written==1;
}
static void migrateProfile(const fs::path& source,const fs::path& target){
 if(source.empty()||source==target)return;
 // Copy only existing editor settings/backups; never replace newer settings.
 std::error_code ec;fs::directory_iterator it(source,fs::directory_options::skip_permission_denied,ec),end;
 for(;!ec&&it!=end;it.increment(ec)){
  auto name=it->path().filename();bool dir=it->is_directory(ec);if(ec){ec.clear();continue;}
  if(dir){
   if(name!=L"originals"&&name!=L"backups")continue;
   DWORD error=0;if(!directories(target/name,error))continue;
   std::error_code nested;fs::directory_iterator sub(it->path(),fs::directory_options::skip_permission_denied,nested);
   for(;!nested&&sub!=end;sub.increment(nested))if(sub->is_regular_file(nested))CopyFileW(sub->path().c_str(),(target/name/sub->path().filename()).c_str(),TRUE);
  }else if(!dir&&it->is_regular_file(ec)&&(it->path().extension()==L".txt"||it->path().extension()==L".ini")){
   CopyFileW(it->path().c_str(),(target/name).c_str(),TRUE);
  }
 }
}
static fs::path chooseProfile(const fs::path& beside,const fs::path& local){
 const auto original=local.empty()?fs::path{}:local/L"SHODAN"/L"StatEditor";
 std::vector<fs::path> candidates;
 auto explicitPath=environmentPath(L"SHODAN_PROFILE");if(!explicitPath.empty())candidates.push_back(explicitPath);
 if(!original.empty())candidates.push_back(original);
 candidates.push_back(beside/L".SHODAN"/L"Profile");
 candidates.push_back(cache.parent_path().parent_path()/L"Profile");
 for(const auto& candidate:candidates){DWORD error=0;if(writable(candidate,error)){
  if(explicitPath.empty())migrateProfile(original,candidate);
  return candidate;
 }}
 throw std::runtime_error("No writable editor settings directory is available");
}
static bool prepareRuntime(const fs::path& candidate,const std::string& manifest,const std::string& payload);
static std::string digest(const fs::path& file){
 BCRYPT_ALG_HANDLE alg=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return {};
 DWORD size=0,n=0;BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&size),sizeof size,&n,0);
 std::vector<unsigned char> object(size);unsigned char result[32];std::string out;
 if(BCryptCreateHash(alg,&hash,object.data(),size,nullptr,0,0)>=0){
  std::ifstream f(file,std::ios::binary);char block[65536];
  if(f){while(f){f.read(block,sizeof block);if(f.gcount())BCryptHashData(hash,reinterpret_cast<PUCHAR>(block),ULONG(f.gcount()),0);}
   if(BCryptFinishHash(hash,result,sizeof result,0)>=0){const char* hex="0123456789abcdef";for(auto c:result){out+=hex[c>>4];out+=hex[c&15];}}
  }BCryptDestroyHash(hash);
 }BCryptCloseAlgorithmProvider(alg,0);return out;
}
static bool verify(const std::string& manifest){
 std::istringstream stream(manifest);std::string line;
 while(std::getline(stream,line)){
  if(!line.empty()&&line.back()=='\r')line.pop_back();
  if(line.size()<66)continue;
  auto relative=fs::u8path(line.substr(65));
  if(relative.is_absolute())return false;
  for(const auto& part:relative)if(part=="..")return false;
  if(digest(cache/relative)!=line.substr(0,64))return false;
 }return true;
}
static void* DIAMONDAPI alloc(ULONG n){return std::malloc(n);}
static void DIAMONDAPI release(void* p){std::free(p);}
static INT_PTR DIAMONDAPI openCab(char* name,int,int){
 auto p=wide(name);auto h=CreateFileW(p.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);
 return h==INVALID_HANDLE_VALUE?-1:reinterpret_cast<INT_PTR>(h);
}
static UINT DIAMONDAPI readCab(INT_PTR h,void* p,UINT n){DWORD done=0;return ReadFile(reinterpret_cast<HANDLE>(h),p,n,&done,nullptr)?done:UINT(-1);}
static UINT DIAMONDAPI writeCab(INT_PTR h,void* p,UINT n){DWORD done=0;return WriteFile(reinterpret_cast<HANDLE>(h),p,n,&done,nullptr)?done:UINT(-1);}
static int DIAMONDAPI closeCab(INT_PTR h){return CloseHandle(reinterpret_cast<HANDLE>(h))?0:-1;}
static long DIAMONDAPI seekCab(INT_PTR h,long distance,int origin){
 LARGE_INTEGER offset,result;offset.QuadPart=distance;
 return SetFilePointerEx(reinterpret_cast<HANDLE>(h),offset,&result,origin)?long(result.QuadPart):-1;
}
static INT_PTR DIAMONDAPI notify(FDINOTIFICATIONTYPE type,PFDINOTIFICATION p){
 if(type==fdintCOPY_FILE){
  auto relative=fs::u8path(p->psz1);if(relative.is_absolute())return -1;
  for(const auto& part:relative)if(part=="..")return -1;
  DWORD error=0;auto target=cache/relative;if(!directories(target.parent_path(),error))return -1;
  auto h=CreateFileW(target.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
  return h==INVALID_HANDLE_VALUE?-1:reinterpret_cast<INT_PTR>(h);
 }
 if(type==fdintCLOSE_FILE_INFO){return closeCab(p->hf)==0;}
 return 0;
}

static bool prepareRuntime(const fs::path& candidate,const std::string& manifest,const std::string& payload){
 cache=candidate;
 if(verify(manifest))return true;
 auto cab=cache/L"payload.cab";
 {std::ofstream f(cab,std::ios::binary);f.write(payload.data(),payload.size());if(!f)return false;}
 ERF error{};auto fdi=FDICreate(alloc,release,openCab,readCab,writeCab,closeCab,seekCab,cpu80386,&error);
 auto folder=cache.generic_u8string()+"/";char name[]="payload.cab";
 BOOL ok=fdi&&FDICopy(fdi,name,folder.data(),0,notify,nullptr,nullptr);
 if(fdi)FDIDestroy(fdi);
 if(!ok||!verify(manifest))return false;
 DeleteFileW(cab.c_str());return true;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int){
 HANDLE mutex=nullptr;
 try{
  const auto manifest=resource(102),payload=resource(101),build=resource(103);
  wchar_t program[32768];if(!GetModuleFileNameW(nullptr,program,32768))throw std::runtime_error("Cannot locate the executable");
  const auto beside=fs::path(program).parent_path(),local=environmentPath(L"LOCALAPPDATA");
  std::vector<fs::path> candidates;
  if(!local.empty())candidates.push_back(local/L"SHODAN"/L"DesktopRuntime"/wide(build));
  candidates.push_back(beside/L".SHODAN"/L"Runtime"/wide(build));
  auto temp=environmentPath(L"TEMP");if(!temp.empty())candidates.push_back(temp/L"SHODAN"/L"DesktopRuntime"/wide(build));
  auto roaming=environmentPath(L"APPDATA");if(!roaming.empty())candidates.push_back(roaming/L"SHODAN"/L"DesktopRuntime"/wide(build));
  auto mutexName=L"Local\\SHODAN_EUI_"+wide(build);
  mutex=CreateMutexW(nullptr,FALSE,mutexName.c_str());
  DWORD result=WaitForSingleObject(mutex,30000);if(result!=WAIT_OBJECT_0&&result!=WAIT_ABANDONED)throw std::runtime_error("Another instance is preparing the runtime");
  bool ready=false;std::string failures;
  for(const auto& candidate:candidates){
   DWORD error=0;
   if(!writable(candidate,error)){failures+=candidate.generic_u8string()+" (Windows error "+std::to_string(error)+")\n";continue;}
   if(prepareRuntime(candidate,manifest,payload)){ready=true;break;}
   failures+=candidate.generic_u8string()+" (payload extraction failed)\n";
  }
  if(!ready)throw std::runtime_error("No writable runtime directory:\n"+failures);
  auto profile=chooseProfile(beside,local);
  SetEnvironmentVariableW(L"SHODAN_PROFILE",profile.c_str());
  ReleaseMutex(mutex);CloseHandle(mutex);mutex=nullptr;
  if(const char* qa=std::getenv("SHODAN_EUI_QA")){
   DWORD error=0;auto out=fs::u8path(qa);directories(out,error);
   std::ofstream(out/L"launcher-paths.txt")<<"runtime="<<cache.generic_u8string()<<"\nprofile="<<profile.generic_u8string()<<"\n";
  }
  auto exe=cache/L"shodan.exe";auto command=L"\""+exe.wstring()+L"\"";
  STARTUPINFOW startup{};startup.cb=sizeof startup;PROCESS_INFORMATION child{};
  DWORD directoryError=0;auto logs=profile/L"Logs";directories(logs,directoryError);
  auto logPath=logs/(L"startup-"+std::to_wstring(GetCurrentProcessId())+L".log");
  SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE log=CreateFileW(logPath.c_str(),FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
  HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
  if(log!=INVALID_HANDLE_VALUE){std::string header="runtime="+cache.generic_u8string()+"\nprofile="+profile.generic_u8string()+"\n";DWORD done=0;WriteFile(log,header.data(),DWORD(header.size()),&done,nullptr);
   startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdOutput=log;startup.hStdError=log;startup.hStdInput=input;
  }
  BOOL launched=CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,log!=INVALID_HANDLE_VALUE,0,nullptr,cache.c_str(),&startup,&child);DWORD launchError=GetLastError();
  if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);if(log!=INVALID_HANDLE_VALUE)CloseHandle(log);
  if(!launched)throw std::runtime_error("Could not start the editor (Windows error "+std::to_string(launchError)+"). Log: "+logPath.generic_u8string());
  CloseHandle(child.hThread);WaitForSingleObject(child.hProcess,INFINITE);DWORD code=0;GetExitCodeProcess(child.hProcess,&code);CloseHandle(child.hProcess);
  if(code){std::ostringstream report;report<<"界面进程异常退出，错误码 0x"<<std::hex<<code<<"。\n启动日志："<<logPath.generic_u8string();
   if(code==0xC0000135)report<<"\n缺少运行依赖，请尝试完整解压 ZIP 版运行。";
   if(code==0xC000001D)report<<"\n处理器不支持所需指令。";
   if(!std::getenv("SHODAN_EUI_QA"))MessageBoxW(nullptr,wide(report.str()).c_str(),L"SHODAN 启动失败",MB_OK|MB_ICONERROR);
   else std::ofstream(fs::u8path(std::getenv("SHODAN_EUI_QA"))/"child-error.txt")<<report.str();
  }return int(code);
 }catch(const std::exception& e){
  if(mutex){ReleaseMutex(mutex);CloseHandle(mutex);}
  if(const char* qa=std::getenv("SHODAN_EUI_QA")){
   DWORD error=0;directories(fs::u8path(qa),error);
   std::ofstream(fs::u8path(qa)/"launcher-error.txt")<<e.what();return 1;
  }
  auto message=L"启动失败："+wide(e.what())+L"\n已尝试用户缓存、程序旁目录与临时目录，请将 EXE 放到可写文件夹。";
  MessageBoxW(nullptr,message.c_str(),L"SHODAN 数值编辑器",MB_OK|MB_ICONERROR);return 1;
 }
}
