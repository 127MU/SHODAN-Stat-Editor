#pragma once
#include <filesystem>
#include <string>
#include <vector>
namespace shodan {
struct ModFile{std::string name,label,data,path;};
struct ModOption {std::string name,description;std::vector<std::string> include;std::vector<ModOption> children;bool required=false;};
struct ModArchive{std::vector<ModFile> files;int ignored=0;std::string title,description;std::vector<ModOption> options;};
ModArchive readModZip(const std::filesystem::path& path);
bool isPatchFile(const std::string& name);
std::vector<ModFile> selectedModFiles(const ModArchive&,const std::vector<int>& choices);
void writeModZip(const std::filesystem::path& path,const std::vector<ModFile>& files);
}
