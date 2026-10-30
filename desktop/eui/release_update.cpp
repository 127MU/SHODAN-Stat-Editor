#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winhttp.h>
#include <yyjson.h>
#include "release_update.h"
#include <array>
#include <charconv>
#include <memory>
#include <regex>
#include <stdexcept>
namespace shodan {
namespace {
bool versionParts(const std::string& text,std::array<unsigned,4>& out){
 static const std::regex pattern("^v?([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-r([0-9]+))?$");
 std::smatch match;if(!std::regex_match(text,match,pattern))return false;
 for(size_t i=0;i<out.size();++i){out[i]=0;const auto part=match[i+1].str();
  if(!part.empty()){auto result=std::from_chars(part.data(),part.data()+part.size(),out[i]);if(result.ec!=std::errc())return false;}
 }return true;
}
std::string string(yyjson_val* root,const char* key){auto* value=yyjson_obj_get(root,key);return yyjson_is_str(value)?std::string(yyjson_get_str(value),yyjson_get_len(value)):std::string{};}
struct Handle {HINTERNET value=nullptr;explicit Handle(HINTERNET v):value(v){if(!v)throw std::runtime_error("无法连接 GitHub，请检查网络后重试");}~Handle(){WinHttpCloseHandle(value);}Handle(const Handle&)=delete;};
}
bool releaseNewer(const std::string& candidate,const std::string& current){
 std::array<unsigned,4> a{},b{};return versionParts(candidate,a)&&versionParts(current,b)&&a>b;
}
ReleaseUpdate parseReleaseUpdate(const std::string& json,const std::string& current){
 auto doc=std::unique_ptr<yyjson_doc,decltype(&yyjson_doc_free)>(yyjson_read(json.data(),json.size(),0),yyjson_doc_free);
 if(!doc)throw std::runtime_error("GitHub 返回的发行版信息无法解析");
 auto* root=yyjson_doc_get_root(doc.get());if(!yyjson_is_obj(root))throw std::runtime_error("GitHub 返回的发行版信息格式无效");
 auto* draft=yyjson_obj_get(root,"draft");auto* prerelease=yyjson_obj_get(root,"prerelease");
 if(!yyjson_is_bool(draft)||!yyjson_is_bool(prerelease))throw std::runtime_error("GitHub 未返回有效发行版");
 if(yyjson_get_bool(draft)||yyjson_get_bool(prerelease))return {};
 ReleaseUpdate result;result.version=string(root,"tag_name");result.url=string(root,"html_url");
 result.notes=string(root,"body");
 std::array<unsigned,4> parts{};if(!versionParts(result.version,parts))return {};
 if(result.url!="https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/"+result.version)throw std::runtime_error("发行版链接与项目地址不匹配");
 const std::string prefix="https://github.com/127MU/SHODAN-Stat-Editor/releases/download/"+result.version+"/";
 const auto version=result.version.front()=='v'?result.version.substr(1):result.version;
 const auto preferred="SHODAN_"+version+".exe";
 auto* assets=yyjson_obj_get(root,"assets");size_t index,max;yyjson_val* asset;
 yyjson_arr_foreach(assets,index,max,asset){
  const auto name=string(asset,"name"),url=string(asset,"browser_download_url");
  if(url.compare(0,prefix.size(),prefix)==0 && name.size()>4 && name.substr(name.size()-4)==".exe"){
   if(result.downloadUrl.empty() || name==preferred)result.downloadUrl=url;
   if(name==preferred)break;
  }
 }
 result.newer=releaseNewer(result.version,current);return result;
}
namespace {
ReleaseResponse requestReleasePath(bool api,const std::string& path,bool mirror=false){
  Handle session(WinHttpOpen(L"SHODAN-Stat-Editor-Update/1.0",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,0));
  WinHttpSetTimeouts(session.value,2500,3000,3000,3000);
  Handle connection(WinHttpConnect(session.value,mirror?L"gh-proxy.com":(api?L"api.github.com":L"github.com"),INTERNET_DEFAULT_HTTPS_PORT,0));
  const auto routedPath=mirror?"/https://api.github.com"+path:path;
  const std::wstring widePath(routedPath.begin(),routedPath.end());
  Handle request(WinHttpOpenRequest(connection.value,L"GET",widePath.c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,WINHTTP_FLAG_SECURE));
  DWORD redirects=WINHTTP_OPTION_REDIRECT_POLICY_NEVER;WinHttpSetOption(request.value,WINHTTP_OPTION_REDIRECT_POLICY,&redirects,sizeof redirects);
  const wchar_t* headers=api?L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n":L"Accept: text/html\r\n";
  if(!WinHttpSendRequest(request.value,headers,DWORD(-1),WINHTTP_NO_REQUEST_DATA,0,0,0)||!WinHttpReceiveResponse(request.value,nullptr))throw std::runtime_error("检查更新失败，请检查网络后重试");
  DWORD status=0,size=sizeof status;
  if(!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&size,WINHTTP_NO_HEADER_INDEX))throw std::runtime_error("无法读取发行版响应状态");
  ReleaseResponse response;response.status=status;
  if(status==301||status==302||status==303||status==307||status==308){
   DWORD bytes=0;WinHttpQueryHeaders(request.value,WINHTTP_QUERY_LOCATION,WINHTTP_HEADER_NAME_BY_INDEX,nullptr,&bytes,WINHTTP_NO_HEADER_INDEX);
   if(!bytes||bytes>16384)throw std::runtime_error("发行版地址无效");
   std::wstring location(bytes/sizeof(wchar_t)+1,L'\0');
   if(!WinHttpQueryHeaders(request.value,WINHTTP_QUERY_LOCATION,WINHTTP_HEADER_NAME_BY_INDEX,location.data(),&bytes,WINHTTP_NO_HEADER_INDEX))throw std::runtime_error("无法读取发行版地址");
   for(wchar_t c:location){if(!c)break;if(c>127)throw std::runtime_error("发行版地址格式无效");response.location+=char(c);}
   return response;
  }
  if(status!=200)return response;
  std::string json;char buffer[16384];DWORD read=0;
  while(true){if(!WinHttpReadData(request.value,buffer,sizeof buffer,&read))throw std::runtime_error("读取发行版信息失败，请稍后重试");if(!read)break;
   if(json.size()+read>1024*1024)throw std::runtime_error("发行版信息过大，已停止读取");json.append(buffer,read);
  }
  response.body=std::move(json);return response;
}
ReleaseResponse requestRelease(bool api){return requestReleasePath(api,api?"/repos/127MU/SHODAN-Stat-Editor/releases/latest":"/127MU/SHODAN-Stat-Editor/releases/latest");}
std::string entities(std::string text){
 for(const auto& pair:std::array<std::pair<const char*,const char*>,7>{{{"&lt;","<"},{"&gt;",">"},{"&quot;","\""},{"&apos;","'"},{"&#39;","'"},{"&nbsp;"," "},{"&amp;","&"}}}){
  size_t at=0;while((at=text.find(pair.first,at))!=std::string::npos){text.replace(at,std::char_traits<char>::length(pair.first),pair.second);at+=std::char_traits<char>::length(pair.second);}
 }return text;
}
}
std::string releaseNotesFromFeed(const std::string& atom,const std::string& version){
 std::array<unsigned,4> parts{};if(!versionParts(version,parts))return {};
 const auto url="https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/"+version;
 const std::regex entries("<entry>[\\s\\S]*?</entry>");
 for(std::sregex_iterator i(atom.begin(),atom.end(),entries),end;i!=end;++i){
  const auto entry=i->str();if(entry.find("href=\""+url+"\"")==std::string::npos&&entry.find("href='"+url+"'")==std::string::npos)continue;
  std::smatch content;if(!std::regex_search(entry,content,std::regex("<content[^>]*>([\\s\\S]*?)</content>")))return {};
  auto text=entities(content[1].str());
  text=std::regex_replace(text,std::regex("<li[^>]*>"),"- ");
  text=std::regex_replace(text,std::regex("</(?:p|li|h[1-6]|pre|div)>|<br\\s*/?>"),"\n");
  text=entities(std::regex_replace(text,std::regex("<[^>]*>"),""));
  const auto first=text.find_first_not_of(" \t\r\n");if(first==std::string::npos)return {};
  return text.substr(first,text.find_last_not_of(" \t\r\n")-first+1);
 }return {};
}
std::string releaseDownloadFromAssets(const std::string& html,const std::string& version){
 std::array<unsigned,4> parts{};if(!versionParts(version,parts))return {};
 const auto prefix="https://github.com/127MU/SHODAN-Stat-Editor/releases/download/"+version+"/";
 const auto number=version.front()=='v'?version.substr(1):version;
 const auto preferred="SHODAN_"+number+".exe";std::string chosen;
 const std::regex links("href=[\"']([^\"']+)[\"']");
 for(std::sregex_iterator i(html.begin(),html.end(),links),end;i!=end;++i){
  auto url=entities((*i)[1].str());if(!url.empty()&&url.front()=='/')url="https://github.com"+url;
  if(url.compare(0,prefix.size(),prefix)!=0)continue;
  const auto name=url.substr(prefix.size());if(name.size()<5||name.substr(name.size()-4)!=".exe"||name.find('/')!=std::string::npos)continue;
  if(chosen.empty()||name==preferred)chosen=url;if(name==preferred)break;
 }return chosen;
}
ReleaseUpdate releaseFromLocation(const std::string& location,const std::string& current){
 const std::string prefix="https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/";
 const auto url=location.size()&&location.front()=='/'?"https://github.com"+location:location;
 if(url.compare(0,prefix.size(),prefix)!=0)throw std::runtime_error("发行版链接与项目地址不匹配");
 ReleaseUpdate result;result.version=url.substr(prefix.size());result.url=url;std::array<unsigned,4> parts{};
 if(!versionParts(result.version,parts))throw std::runtime_error("最新正式发行版的版本号无法识别");
 result.newer=releaseNewer(result.version,current);return result;
}
static ReleaseUpdate checkOfficialReleaseUpdate(const std::string& current,const ReleaseFetch& provided,const ReleasePageFetch& pages){
 const ReleaseFetch fetch=provided?provided:ReleaseFetch(requestRelease);
 const ReleasePageFetch publicPage=pages?pages:(provided?ReleasePageFetch{}:ReleasePageFetch([](const std::string& path){return requestReleasePath(false,path);}));
 // One startup check cycle: the public Latest release redirect, then at most
 // one API request when needed (new release notes/assets, or redirect fallback).
 try{
  const auto page=fetch(false);
  if(page.status==301||page.status==302||page.status==303||page.status==307||page.status==308){
   auto latest=releaseFromLocation(page.location,current);
   if(!latest.newer)return latest;
   try{
    const auto api=fetch(true);
    if(api.status==200){auto detail=parseReleaseUpdate(api.body,current);if(detail.newer){latest=detail;if(!latest.notes.empty()&&!latest.downloadUrl.empty())return latest;}}
   }catch(const std::exception&){}
   if(publicPage){
    if(latest.notes.empty())try{const auto feed=publicPage("/127MU/SHODAN-Stat-Editor/releases.atom");if(feed.status==200)latest.notes=releaseNotesFromFeed(feed.body,latest.version);}catch(const std::exception&){}
    if(latest.downloadUrl.empty())try{const auto assets=publicPage("/127MU/SHODAN-Stat-Editor/releases/expanded_assets/"+latest.version);if(assets.status==200)latest.downloadUrl=releaseDownloadFromAssets(assets.body,latest.version);}catch(const std::exception&){}
   }
   if(latest.notes.empty())latest.notes="暂时无法获取更新日志，请点击“查看发行版”查看完整说明。";
   return latest;
  }
 }catch(const std::exception&){}
 try{
  const auto api=fetch(true);
  if(api.status!=200)throw std::runtime_error(api.status==403||api.status==429?"暂时无法检查更新：GitHub 访问受限，可稍后手动重试":"暂时无法获取正式发行版，请稍后手动重试");
  return parseReleaseUpdate(api.body,current);
 }catch(const std::exception& e){ReleaseUpdate result;result.error=e.what();return result;}
}
ReleaseUpdate checkReleaseUpdate(const std::string& current,const ReleaseFetch& provided,const ReleasePageFetch& pages,const ReleaseFetch& mirror){
 auto result=checkOfficialReleaseUpdate(current,provided,pages);
 const bool incomplete=result.newer&&(result.downloadUrl.empty()||result.notes.empty()||result.notes.find("暂时无法获取更新日志")==0);
 if(result.error.empty()&&!incomplete)return result;
 // Public metadata only; no GitHub token or game traffic goes to the mirror.
 const ReleaseFetch fallback=mirror?mirror:(provided?ReleaseFetch{}:ReleaseFetch([](bool){return requestReleasePath(true,"/repos/127MU/SHODAN-Stat-Editor/releases/latest",true);}));
 if(fallback)try{
  const auto response=fallback(true);
  if(response.status==200){
   auto mirrored=parseReleaseUpdate(response.body,current);
   // Cached metadata must never replace a newer version obtained from GitHub.
   if(!mirrored.version.empty()&&(result.version.empty()||!releaseNewer(result.version,mirrored.version))){
    if(!mirrored.downloadUrl.empty())mirrored.downloadUrl="https://gh-proxy.com/"+mirrored.downloadUrl;
    mirrored.notes+=(mirrored.notes.empty()?"":"\n\n")+std::string("更新信息通过 GH-Proxy 镜像获取；发行版来源：")+mirrored.url;
    return mirrored;
   }
  }
 }catch(const std::exception&){}
 if(!result.error.empty())result.error="GitHub 和更新镜像暂时均不可用，请稍后重试。";
 return result;
}
}
