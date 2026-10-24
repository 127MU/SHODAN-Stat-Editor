#include "patch_mods.h"
#include <zlib.h>
#include <map>
#include <set>
#include <sstream>
#include <fstream>
#include <iomanip>
#include <chrono>
#include <cstdint>
#include <algorithm>
#include <stdexcept>
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
namespace shodan {namespace {
using Files=std::map<std::string,std::string>;
std::string read(const std::filesystem::path& path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("无法读取 "+path.filename().u8string());return {(std::istreambuf_iterator<char>(f)),{}};}
void write(const std::filesystem::path& path,const std::string& data){std::ofstream f(path,std::ios::binary|std::ios::trunc);if(!f)throw std::runtime_error("无法写入 "+path.filename().u8string());f.write(data.data(),data.size());f.close();if(!f)throw std::runtime_error("文件写入不完整");}
uint64_t word(const std::string& s,size_t at,int n){if(at>s.size()||s.size()-at<size_t(n))throw std::runtime_error("资源补丁索引越界");uint64_t v=0;for(int i=0;i<n;++i)v|=uint64_t(uint8_t(s[at+i]))<<(8*i);return v;}
std::string hex(uint64_t v){std::ostringstream s;s<<std::hex<<std::setw(16)<<std::setfill('0')<<v;return s.str();}
std::string slice(const std::string& s,uint64_t at,uint64_t n){if(n==0)return {};if(at>s.size()||n>s.size()-at)throw std::runtime_error("资源补丁数据越界或缺少配套文件");return s.substr(size_t(at),size_t(n));}
bool mainFile(const std::string& name){return isPatchFile(name)&&name.find('.',17)==std::string::npos;}
std::string suffix(const std::string& name){if(name.size()>=14&&name.substr(name.size()-14)==".gpu_resources")return ".gpu_resources";if(name.size()>=7&&name.substr(name.size()-7)==".stream")return ".stream";return {};}
struct Bundle{std::string package,label,main,stream,gpu;std::set<std::string> present;};
using Resources=std::map<std::string,std::string>;
Resources inspect(const Bundle& b){
 if(word(b.main,0,4)!=0xF0000011)throw std::runtime_error(b.label+"：不支持的资源补丁格式");
 const auto types=word(b.main,4,4),count=word(b.main,8,4);const uint64_t start=72+types*32,end=start+count*80;
 if(types>4096||count==0||count>100000||end>b.main.size())throw std::runtime_error(b.label+"：资源补丁目录无效");
 Resources out;
 for(size_t i=0;i<count;++i){size_t p=size_t(start)+i*80;auto id=word(b.main,p,8),type=word(b.main,p+8,8);auto offset=word(b.main,p+16,8),size=word(b.main,p+56,4);
  if(size&&offset<end)throw std::runtime_error("资源数据与目录重叠");
  auto main=slice(b.main,offset,size),stream=slice(b.stream,word(b.main,p+24,8),word(b.main,p+60,4)),gpu=slice(b.gpu,word(b.main,p+32,8),word(b.main,p+64,4));
  const auto key=b.package+" / "+hex(type)+" / "+hex(id);std::string value=std::to_string(main.size())+":"+main+std::to_string(stream.size())+":"+stream+gpu;
  if(!out.emplace(key,std::move(value)).second)throw std::runtime_error("资源补丁内部存在重复条目");
 }return out;
}
std::vector<Bundle> bundles(const std::vector<ModFile>& inputs){
 std::map<std::string,Bundle> grouped;
 for(const auto& file:inputs){if(!isPatchFile(file.name))throw std::runtime_error("非资源补丁文件");const auto ext=suffix(file.name);auto key=file.label.substr(0,file.label.size()-ext.size());auto& b=grouped[key];b.package=file.name.substr(0,16);b.label=key;
  if(!b.present.insert(ext).second)throw std::runtime_error("重复的资源补丁配套文件");
  (ext==".stream"?b.stream:ext==".gpu_resources"?b.gpu:b.main)=file.data;
 }
 std::vector<Bundle> out;for(auto& item:grouped){if(!item.second.present.count(""))throw std::runtime_error("缺少资源补丁主文件："+item.first);out.push_back(std::move(item.second));}return out;
}
struct Entry{uint64_t size=0;uint32_t crc=0;};
using Ledger=std::map<std::string,Entry>;
Entry stamp(const std::string& data){return {data.size(),crc32(0,reinterpret_cast<const Bytef*>(data.data()),uInt(data.size()))};}
bool matches(const std::string& data,const Entry& entry){auto x=stamp(data);return x.size==entry.size&&x.crc==entry.crc;}
std::filesystem::path ledgerPath(const std::filesystem::path& profile){return profile/"patch-install.txt";}
Ledger loadLedger(const std::filesystem::path& data,const std::filesystem::path& profile){
 Ledger result;auto path=ledgerPath(profile);if(!std::filesystem::exists(path))return result;
 std::istringstream f(read(path));std::string root;if(!(f>>std::quoted(root)))throw std::runtime_error("资源补丁安装记录缺少游戏目录");
 while(true){f>>std::ws;if(f.peek()==std::char_traits<char>::eof())break;std::string name;Entry e;
  if(!(f>>std::quoted(name)>>e.size>>e.crc)||!isPatchFile(name)||e.size>128*1024*1024||!result.emplace(name,e).second)throw std::runtime_error("资源补丁安装记录损坏或不完整");
 }
 const auto saved=std::filesystem::weakly_canonical(std::filesystem::u8path(root)).wstring(),current=std::filesystem::weakly_canonical(data).wstring();
 if(!result.empty()&&CompareStringOrdinal(saved.c_str(),-1,current.c_str(),-1,TRUE)!=CSTR_EQUAL)throw std::runtime_error("资源补丁记录属于其他游戏目录，请先在原目录恢复");
 return result;
}
void saveLedger(const std::filesystem::path& data,const std::filesystem::path& profile,const Ledger& entries){
 std::filesystem::create_directories(profile);std::ostringstream s;s<<std::quoted(std::filesystem::weakly_canonical(data).u8string())<<'\n';for(const auto& e:entries)s<<std::quoted(e.first)<<' '<<e.second.size<<' '<<e.second.crc<<'\n';
 auto path=ledgerPath(profile),temp=profile/"patch-install.txt.tmp";write(temp,s.str());if(!MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("无法提交资源补丁安装记录");
}
void verifyOwned(const std::filesystem::path& data,const Ledger& ledger){for(const auto& e:ledger)if(std::filesystem::exists(data/e.first)&&!matches(read(data/e.first),e.second))throw std::runtime_error(e.first+" 已被其他程序更改，停止移除以保护该文件");}
}
std::vector<ModFile> combinePatchFiles(const std::vector<ModFile>& inputs){
 std::map<std::string,std::pair<std::string,std::string>> seen;std::map<std::string,int> next;std::vector<ModFile> output;
 for(const auto& b:bundles(inputs)){
  bool fresh=false;for(const auto& entry:inspect(b)){auto found=seen.find(entry.first);if(found!=seen.end()&&found->second.first!=entry.second)throw std::runtime_error("资源冲突："+found->second.second+" 与 "+b.label+"；资源 "+entry.first+"。请关闭其中一个 Mod 或使用已合并兼容版本");if(found==seen.end()){fresh=true;seen.emplace(entry.first,std::make_pair(entry.second,b.label));}}
  if(!fresh)continue;const auto name=b.package+".patch_"+std::to_string(next[b.package]++);
  output.push_back({name,b.label+" / "+name,b.main});output.push_back({name+".stream",b.label+" / "+name+".stream",b.stream});output.push_back({name+".gpu_resources",b.label+" / "+name+".gpu_resources",b.gpu});
 }return output;
}
void checkPatchDeployment(const std::filesystem::path& data,const std::filesystem::path& profile,const std::vector<ModFile>& files){
 auto owned=loadLedger(data,profile);verifyOwned(data,owned);
 if(files.empty())return;
 std::map<std::string,std::string> requested;std::set<std::string> packages;
 for(const auto& b:bundles(files)){packages.insert(b.package);auto entries=inspect(b);requested.insert(entries.begin(),entries.end());}
 for(const auto& item:std::filesystem::directory_iterator(data)){
  const auto name=item.path().filename().u8string();if(!mainFile(name)||owned.count(name)||!packages.count(name.substr(0,16)))continue;
  Bundle b;b.package=name.substr(0,16);b.label=name;b.main=read(item.path());
  if(std::filesystem::exists(data/(name+".stream")))b.stream=read(data/(name+".stream"));if(std::filesystem::exists(data/(name+".gpu_resources")))b.gpu=read(data/(name+".gpu_resources"));
  for(const auto& e:inspect(b)){auto found=requested.find(e.first);if(found!=requested.end()&&found->second!=e.second)throw std::runtime_error("与游戏目录中的现有补丁 "+name+" 冲突："+e.first+"；请先在原管理器停用对应 Mod");}
 }
}
struct PatchTransaction::Impl {
 std::filesystem::path data,profile,stage;Ledger old,pending,desired;Files oldData,newData;std::vector<std::string> created;bool finished=false,active=false;
 Impl(const std::filesystem::path& d,const std::filesystem::path& p,const std::vector<ModFile>& input):data(d),profile(p){
  checkPatchDeployment(data,profile,input);old=loadLedger(data,profile);if(old.empty()&&input.empty()){finished=true;return;}
  for(const auto& item:old)if(std::filesystem::exists(data/item.first))oldData[item.first]=read(data/item.first);
  std::map<std::string,std::string> rename;std::map<std::string,int> next;
  for(const auto& file:input){const auto ext=suffix(file.name),base=file.name.substr(0,file.name.size()-ext.size());if(!rename.count(base)){
   const auto package=base.substr(0,16);int& index=next[package];std::string name;
   for(;;){if(index>9999)throw std::runtime_error("资源补丁编号已用尽");name=package+".patch_"+std::to_string(index++);if(!std::filesystem::exists(data/name)&&!std::filesystem::exists(data/(name+".stream"))&&!std::filesystem::exists(data/(name+".gpu_resources"))&&!old.count(name))break;}
   rename[base]=name;
  }const auto name=rename[base]+ext;newData[name]=file.data;desired[name]=stamp(file.data);}
  stage=data/(".shodan-stage-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  if(!std::filesystem::create_directory(stage))throw std::runtime_error("无法创建资源补丁暂存目录");
  try{for(const auto& f:newData)write(stage/f.first,f.second);pending=old;pending.insert(desired.begin(),desired.end());saveLedger(data,profile,pending);active=true;}catch(...){std::error_code ec;std::filesystem::remove_all(stage,ec);throw;}
 }
 void rollback() noexcept {
  if(!active)return;
  try{
   for(const auto& name:created)if(std::filesystem::exists(data/name)&&matches(read(data/name),desired.at(name)))std::filesystem::remove(data/name);
   for(const auto& item:oldData)if(!std::filesystem::exists(data/item.first))write(data/item.first,item.second);
   saveLedger(data,profile,old);
  }catch(...){} // The durable pending ledger keeps ownership after an interrupted rollback.
  std::error_code ec;std::filesystem::remove_all(stage,ec);active=false;
 }
 void commit(){if(finished)return;
  try{
   verifyOwned(data,old);
   for(const auto& file:newData){if(!MoveFileExW((stage/file.first).c_str(),(data/file.first).c_str(),MOVEFILE_WRITE_THROUGH))throw std::runtime_error("无法部署资源补丁 "+file.first);created.push_back(file.first);if(read(data/file.first)!=file.second)throw std::runtime_error("资源补丁回读校验失败");}
   verifyOwned(data,old);for(const auto& item:old)if(std::filesystem::exists(data/item.first)&&!std::filesystem::remove(data/item.first))throw std::runtime_error("无法移除已关闭的补丁 "+item.first);
   saveLedger(data,profile,desired);active=false;finished=true;std::error_code ec;std::filesystem::remove_all(stage,ec);
  }catch(...){rollback();throw;}
 }
 ~Impl(){if(active)rollback();}
};
PatchTransaction::PatchTransaction(const std::filesystem::path& data,const std::filesystem::path& profile,const std::vector<ModFile>& files):impl(std::make_unique<Impl>(data,profile,files)){}
PatchTransaction::~PatchTransaction()=default;
void PatchTransaction::commit(){impl->commit();}
}
