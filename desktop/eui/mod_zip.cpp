#include "mod_zip.h"
#include <zlib.h>
#include "eui/json.h"
#include <algorithm>
#include <cstdint>
#include <cctype>
#include <regex>
#include <chrono>
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fstream>
#include <set>
#include <stdexcept>
#include <limits>

namespace shodan {
namespace {
constexpr size_t FileLimit=128*1024*1024,TotalLimit=512*1024*1024;
uint16_t u16(const std::string& s,size_t p){if(p>s.size()||s.size()-p<2)throw std::runtime_error("ZIP 字段越界");return uint8_t(s[p])|(uint16_t(uint8_t(s[p+1]))<<8);}
uint32_t u32(const std::string& s,size_t p){return u16(s,p)|(uint32_t(u16(s,p+2))<<16);}
void put16(std::string& s,uint16_t v){s+=char(v);s+=char(v>>8);}
void put32(std::string& s,uint32_t v){put16(s,uint16_t(v));put16(s,uint16_t(v>>16));}
bool safeName(const std::string& name){
 if(name.empty()||name[0]=='/'||name[0]=='\\'||name.find(':')!=std::string::npos||name.find('\0')!=std::string::npos)return false;
 std::string clean=name;std::replace(clean.begin(),clean.end(),'\\','/');
 size_t at=0;while(at<clean.size()){auto end=clean.find('/',at);auto part=clean.substr(at,end-at);if(part=="..")return false;if(end==std::string::npos)break;at=end+1;}return true;
}
std::string basename(std::string name){std::replace(name.begin(),name.end(),'\\','/');auto at=name.find_last_of('/');return at==std::string::npos?name:name.substr(at+1);}
}
bool isPatchFile(const std::string& name){static const std::regex pattern("^[0-9a-fA-F]{16}\\.patch_[0-9]+(\\.gpu_resources|\\.stream)?$");return std::regex_match(name,pattern);}
std::string jsonString(eui::json::Value value,const std::string& key){std::string result;value.get(key).string(result);return result;}
ModOption parseOption(eui::json::Value value,int depth=0){
 if(depth>4||value.type()!=eui::json::Type::Object)throw std::runtime_error("Mod 选项层级无效");
 ModOption out;out.name=jsonString(value,"Name");out.description=jsonString(value,"Description");
 value.get("Required").boolean(out.required);if(out.name=="Core")out.required=true;
 auto includes=value.get("Include");if(includes.valid()&&includes.type()!=eui::json::Type::Array)throw std::runtime_error("Mod Include 必须是目录列表");
 for(size_t i=0;i<includes.size();++i){std::string dir;if(!includes.at(i).string(dir)||!safeName(dir))throw std::runtime_error("Mod Include 目录无效");std::replace(dir.begin(),dir.end(),'\\','/');while(!dir.empty()&&dir.back()=='/')dir.pop_back();out.include.push_back(dir);}
 auto children=value.get("SubOptions");if(children.size()>64)throw std::runtime_error("Mod 子选项过多");
 for(size_t i=0;i<children.size();++i)out.children.push_back(parseOption(children.at(i),depth+1));
 return out;
}
std::vector<ModFile> selectedModFiles(const ModArchive& zip,const std::vector<int>& choices){
 if(zip.options.empty())return zip.files;
 std::vector<std::string> dirs;
 for(size_t i=0;i<zip.options.size();++i){const auto& option=zip.options[i];const int choice=i<choices.size()?choices[i]:1;
  if(choice==0){if(option.required)throw std::runtime_error(option.name+" 为必选项");continue;}
  dirs.insert(dirs.end(),option.include.begin(),option.include.end());
  if(!option.children.empty()){
   if(choice<1||size_t(choice)>option.children.size())throw std::runtime_error("Mod 子选项编号无效");
   const auto& child=option.children[choice-1];if(!child.children.empty())throw std::runtime_error("暂不支持超过一层的 Mod 子选项，请先整理选项包");
   dirs.insert(dirs.end(),child.include.begin(),child.include.end());
  }
 }
 std::vector<ModFile> result;
 for(const auto& file:zip.files)for(const auto& dir:dirs)if(file.path==dir||(file.path.size()>dir.size()&&file.path.compare(0,dir.size(),dir)==0&&file.path[dir.size()]=='/')){result.push_back(file);break;}
 if(result.empty())throw std::runtime_error("所选 Mod 选项不包含可安装文件");return result;
}
ModArchive readModZip(const std::filesystem::path& path){
 if(std::filesystem::file_size(path)>256*1024*1024)throw std::runtime_error("ZIP 超过 256 MB 上限");
 std::ifstream in(path,std::ios::binary);if(!in)throw std::runtime_error("无法读取 ZIP");
 std::string raw((std::istreambuf_iterator<char>(in)),{});
 if(raw.size()<22)throw std::runtime_error("ZIP 文件不完整");
 size_t end=std::string::npos;
 const size_t lower=raw.size()>65557?raw.size()-65557:0;
 for(size_t p=raw.size()-22;;--p){if(u32(raw,p)==0x06054b50&&p+22+u16(raw,p+20)==raw.size()){end=p;break;}if(p==lower)break;}
 if(end==std::string::npos)throw std::runtime_error("无法找到 ZIP 目录");
 const auto count=u16(raw,end+10);const auto directory=u32(raw,end+16);const auto directorySize=u32(raw,end+12);
 if(u16(raw,end+4)||u16(raw,end+6)||u16(raw,end+8)!=count||count==65535||directory==0xffffffffu||directorySize==0xffffffffu)
  throw std::runtime_error("不支持分卷或 ZIP64 压缩包");
 if(count>2000||directory>end||directorySize>end-directory)throw std::runtime_error("ZIP 目录过大或越界");
 ModArchive result;size_t pos=directory,total=0;
 for(unsigned i=0;i<count;++i){
  if(pos+46>end||u32(raw,pos)!=0x02014b50)throw std::runtime_error("ZIP 目录损坏");
  const auto flags=u16(raw,pos+8),method=u16(raw,pos+10),nameSize=u16(raw,pos+28),extra=u16(raw,pos+30),comment=u16(raw,pos+32);
  const auto crc=u32(raw,pos+16),packed=u32(raw,pos+20),plain=u32(raw,pos+24),local=u32(raw,pos+42);
  if(pos+46+size_t(nameSize)+extra+comment>end)throw std::runtime_error("ZIP 文件名越界");
  const auto name=raw.substr(pos+46,nameSize);pos+=46+size_t(nameSize)+extra+comment;
  if(!safeName(name))throw std::runtime_error("ZIP 含不安全的路径");
  const auto file=basename(name);std::string lowerName=file;std::transform(lowerName.begin(),lowerName.end(),lowerName.begin(),[](unsigned char c){return char(std::tolower(c));});
  const bool isData=(lowerName.size()>=7&&lowerName.substr(lowerName.size()-7)==".dl_bin")||isPatchFile(file);
  const bool metadata=lowerName=="mod.json"||lowerName=="manifest.json"||lowerName=="readme.md"||lowerName=="readme.txt"||lowerName=="mod.txt";
  if(!isData&&(!metadata||plain>65536)){++result.ignored;continue;}
  if(flags&1)throw std::runtime_error("不支持加密 ZIP");
  if(method!=0&&method!=8)throw std::runtime_error("只支持 ZIP 的存储与 Deflate 压缩方式");
  if(plain>FileLimit||total>TotalLimit-plain)throw std::runtime_error("ZIP 内数值文件超过内存限制");total+=plain;
  if(local>directory||directory-local<30||u32(raw,local)!=0x04034b50)throw std::runtime_error("ZIP 本地文件头损坏");
  const auto localName=u16(raw,local+26),localExtra=u16(raw,local+28);
  const size_t start=size_t(local)+30+localName+localExtra;
  if(start>directory||packed>directory-start||u16(raw,local+8)!=method||u16(raw,local+6)!=flags||raw.substr(local+30,localName)!=name)
   throw std::runtime_error("ZIP 本地数据与目录不一致");
  std::string data(plain,'\0');
  if(method==0){if(packed!=plain)throw std::runtime_error("ZIP 存储长度不匹配");data.assign(raw.data()+start,plain);}
  else{
   z_stream stream{};stream.next_in=reinterpret_cast<Bytef*>(raw.data()+start);stream.avail_in=packed;
   unsigned char empty=0;stream.next_out=plain?reinterpret_cast<Bytef*>(data.data()):&empty;stream.avail_out=plain?plain:1;
   if(inflateInit2(&stream,-MAX_WBITS)!=Z_OK)throw std::runtime_error("无法初始化 ZIP 解压");
   const int status=inflate(&stream,Z_FINISH);const bool good=status==Z_STREAM_END&&stream.total_out==plain&&stream.total_in==packed;
   inflateEnd(&stream);if(!good)throw std::runtime_error("ZIP 解压失败或长度不匹配");
  }
  if(crc32(0,reinterpret_cast<const Bytef*>(data.data()),uInt(data.size()))!=crc)throw std::runtime_error("ZIP 文件 CRC 校验失败");
  if(!isData){
   if(lowerName=="mod.json"||lowerName=="manifest.json"){
    eui::json::Document document;if(data.size()>=3&&data.compare(0,3,"\xEF\xBB\xBF")==0)data.erase(0,3);if(!document.parse(data))throw std::runtime_error("Mod 元信息 JSON 格式无效");
    auto root=document.root();auto title=jsonString(root,"Name"),description=jsonString(root,"Description");
    if(title.empty())title=jsonString(root,"name");if(description.empty())description=jsonString(root,"description");
    if(!title.empty())result.title=title;if(!description.empty())result.description=description;
    auto options=root.get("Options");if(options.size()>64)throw std::runtime_error("Mod 选项过多");
    if(options.valid()&&options.type()!=eui::json::Type::Array)throw std::runtime_error("Mod Options 必须是列表");
    for(size_t i=0;i<options.size();++i)result.options.push_back(parseOption(options.at(i)));
    // Include paths are relative to this manifest, including wrapped ZIPs.
    auto slash=name.find_last_of("/\\");if(slash!=std::string::npos){
     auto prefix=name.substr(0,slash+1);std::replace(prefix.begin(),prefix.end(),'\\','/');for(auto& option:result.options){for(auto& dir:option.include)dir=prefix+dir;for(auto& child:option.children)for(auto& dir:child.include)dir=prefix+dir;}
    }

   }else if(result.description.empty()){
    for(char& c:data)if(c=='\r'||c=='\t')c=' ';
    result.description=data.substr(0,1400);
   }
   ++result.ignored;continue;
  }
  std::string normalized=name;std::replace(normalized.begin(),normalized.end(),'\\','/');
  result.files.push_back({file,path.filename().u8string()+" / "+normalized,std::move(data),normalized});
 }
 if(pos!=size_t(directory)+directorySize)throw std::runtime_error("ZIP 目录长度不匹配");
 if(result.files.empty())throw std::runtime_error("ZIP 中没有 .dl_bin 或 .patch_* Mod 文件");
 return result;
}
void writeModZip(const std::filesystem::path& path,const std::vector<ModFile>& files){
 if(files.empty()||files.size()>2000)throw std::runtime_error("没有可导出的合并文件");
 std::string body,central;size_t total=0;std::set<std::string> names;
 for(const auto& f:files){
  if(!safeName(f.name)||f.name.size()>65535||!names.insert(f.name).second||f.data.size()>FileLimit)throw std::runtime_error("导出文件名重复或文件过大");
  total+=f.data.size();if(total>TotalLimit||f.name.size()>65525)throw std::runtime_error("导出内容超过限制");
  const std::string name=(isPatchFile(f.name)?"data/":"data/game/")+f.name;const uint32_t offset=uint32_t(body.size()),size=uint32_t(f.data.size());
  const uint32_t crc=crc32(0,reinterpret_cast<const Bytef*>(f.data.data()),size);
  put32(body,0x04034b50);put16(body,20);put16(body,0x800);put16(body,0);put16(body,0);put16(body,33);
  put32(body,crc);put32(body,size);put32(body,size);put16(body,uint16_t(name.size()));put16(body,0);body+=name;body+=f.data;
  put32(central,0x02014b50);put16(central,20);put16(central,20);put16(central,0x800);put16(central,0);put16(central,0);put16(central,33);
  put32(central,crc);put32(central,size);put32(central,size);put16(central,uint16_t(name.size()));put16(central,0);put16(central,0);put16(central,0);put16(central,0);put32(central,0);put32(central,offset);central+=name;
 }
 const uint32_t directory=uint32_t(body.size());body+=central;
 put32(body,0x06054b50);put16(body,0);put16(body,0);put16(body,uint16_t(files.size()));put16(body,uint16_t(files.size()));put32(body,uint32_t(central.size()));put32(body,directory);put16(body,0);
 const auto temp=path.parent_path()/(path.filename().u8string()+".shodan-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".tmp");
 std::ofstream out(temp,std::ios::binary|std::ios::trunc);if(!out)throw std::runtime_error("无法创建合并 ZIP");out.write(body.data(),std::streamsize(body.size()));out.close();
 if(!out)throw std::runtime_error("写入合并 ZIP 失败");
 auto verified=readModZip(temp);if(verified.files.size()!=files.size())throw std::runtime_error("导出 ZIP 回读数量不一致");
 for(size_t i=0;i<files.size();++i)if(verified.files[i].name!=files[i].name||verified.files[i].data!=files[i].data)throw std::runtime_error("导出 ZIP 回读内容不一致");
 if(!MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)){std::error_code ec;std::filesystem::remove(temp,ec);throw std::runtime_error("无法提交合并 ZIP，请选择可写入的位置");}
}
}
