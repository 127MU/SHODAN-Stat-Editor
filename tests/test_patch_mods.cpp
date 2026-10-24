#include "../desktop/eui/mod_zip.h"
#include "../desktop/eui/patch_mods.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <chrono>
#include <map>
std::string read(const std::filesystem::path& p){std::ifstream f(p,std::ios::binary);return {(std::istreambuf_iterator<char>(f)),{}};}
int main(int argc,char** argv){try{
 const auto root=std::filesystem::absolute(std::filesystem::u8path(argv[1]));std::filesystem::create_directories(root);const auto downloads=std::filesystem::u8path(argv[2]);
 auto fp=shodan::readModZip(downloads/"HD2FP-fix.zip");auto hud=shodan::readModZip(downloads/"HD2 HUD+ 0.1.6 Full Repair 0.5.3 + 头顶照明 Native Beacon 1.2.3 合并版.zip");auto night=shodan::readModZip(downloads/"HD2-Colored-Night-Vision.zip");
 assert(fp.title=="HD2 First Person"&&hud.options.size()==8&&night.options.size()==1);

 auto selected=shodan::selectedModFiles(hud,std::vector<int>(hud.options.size(),1));assert(selected.size()==30);
 bool merged=false,hudonly=false;std::string originalBoot;
 for(const auto& f:selected){if(f.path.find("CORE_MERGED/")==0&&f.data.size()>9000000){merged=true;originalBoot=f.data;}if(f.path.find("CORE_HUDONLY/")==0)hudonly=true;}assert(merged&&!hudonly);
 auto patches=shodan::combinePatchFiles(selected);assert(patches.size()==30);bool sameBoot=false;for(const auto& f:patches)if(f.data==originalBoot)sameBoot=true;assert(sameBoot);
 auto choices=std::vector<int>(hud.options.size(),1);choices[0]=2;choices[3]=0;auto optional=shodan::selectedModFiles(hud,choices);assert(optional.size()==27);for(const auto& f:optional)assert(f.path.find("CORE_MERGED/")!=0&&f.path.find("NUMBERS_")!=0);
 auto alternatives=shodan::combinePatchFiles(optional);assert(alternatives.size()==27);
 for(const auto* z:{&fp,&night}){assert(shodan::combinePatchFiles(shodan::selectedModFiles(*z,{1})).size()==3);}
 auto conflicting=selected;auto first=shodan::selectedModFiles(fp,{1});conflicting.insert(conflicting.end(),first.begin(),first.end());bool rejected=false;try{shodan::combinePatchFiles(conflicting);}catch(const std::exception& e){rejected=std::string(e.what()).find("f476df93691895fa")!=std::string::npos;}assert(rejected);
 shodan::writeModZip(root/"hud-export.zip",patches);auto exported=shodan::readModZip(root/"hud-export.zip");assert(exported.files.size()==30);
 auto data=root/"mock-data",profile=root/"mock-profile";std::filesystem::create_directories(data);
 {std::ofstream(data/"unrelated.txt")<<"do not touch";}
 // A patch installed by another manager must be reported, never overwritten.
 {std::ofstream f(data/"9ba626afa44a3aa3.patch_42",std::ios::binary);f.write(first[0].data.data(),first[0].data.size());}
 rejected=false;try{shodan::checkPatchDeployment(data,profile,patches);}catch(...){rejected=true;}assert(rejected);std::filesystem::remove(data/"9ba626afa44a3aa3.patch_42");
 {shodan::PatchTransaction transaction(data,profile,patches);transaction.commit();}
 std::map<std::string,std::string> installed;for(const auto& f:std::filesystem::directory_iterator(data))if(shodan::isPatchFile(f.path().filename().u8string()))installed[f.path().filename().u8string()]=read(f.path());assert(installed.size()==30);
 {shodan::PatchTransaction transaction(data,profile,alternatives);/* intentionally abandon: roll back staged files */}
 for(const auto& item:installed)assert(read(data/item.first)==item.second);
 // Simulate a new external file appearing between staging and commit.
 {shodan::PatchTransaction transaction(data,profile,alternatives);const auto collision=data/"9ba626afa44a3aa3.patch_10";std::ofstream(collision)<<"external collision";rejected=false;try{transaction.commit();}catch(...){rejected=true;}assert(rejected&&read(collision)=="external collision");for(const auto& item:installed)assert(read(data/item.first)==item.second);std::filesystem::remove(collision);}
 {shodan::PatchTransaction transaction(data,profile,alternatives);transaction.commit();}
 size_t count=0;for(const auto& f:std::filesystem::directory_iterator(data))if(shodan::isPatchFile(f.path().filename().u8string()))++count;assert(count==27);
 {shodan::PatchTransaction transaction(data,profile,{});transaction.commit();}
 for(const auto& f:std::filesystem::directory_iterator(data))assert(!shodan::isPatchFile(f.path().filename().u8string()));assert(read(data/"unrelated.txt")=="do not touch");
 auto different=root/"different-game-data";std::filesystem::create_directories(different);shodan::checkPatchDeployment(different,profile,{});
 // Never delete an owned patch if another program changed it.
 {shodan::PatchTransaction transaction(data,profile,shodan::combinePatchFiles(first));transaction.commit();}
 std::filesystem::path changed;for(const auto& f:std::filesystem::directory_iterator(data))if(shodan::isPatchFile(f.path().filename().u8string())){changed=f.path();break;}
 {std::ofstream(changed,std::ios::binary)<<"external change";}
 rejected=false;try{shodan::PatchTransaction transaction(data,profile,{});transaction.commit();}catch(...){rejected=true;}assert(rejected&&read(changed)=="external change");
 std::cout<<"All three actual ZIPs: import, uppercase manifest, HUD exclusive/default choices, intact merged boot, resource conflict, ZIP roundtrip, staged rollback, reinstall, disable cleanup and external-file protection passed; mock directory only.\n";
}catch(const std::exception& error){std::cerr<<"ERROR: "<<error.what()<<"\n";return 1;}
}
