#pragma once
#include "mod_zip.h"
#include <memory>
namespace shodan {
std::vector<ModFile> combinePatchFiles(const std::vector<ModFile>& inputs);
void checkPatchDeployment(const std::filesystem::path& gameData,const std::filesystem::path& profile,const std::vector<ModFile>& files);
class PatchTransaction {
 struct Impl;std::unique_ptr<Impl> impl;
public:
 PatchTransaction(const std::filesystem::path& gameData,const std::filesystem::path& profile,const std::vector<ModFile>& files);
 ~PatchTransaction();
 void commit();
};
}
