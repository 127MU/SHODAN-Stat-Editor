#pragma once
#include <string>
namespace shodan {
struct ReleaseUpdate {
 std::string version,url,error;
 bool newer=false;
};
bool releaseNewer(const std::string& candidate,const std::string& current);
ReleaseUpdate parseReleaseUpdate(const std::string& json,const std::string& current);
ReleaseUpdate checkReleaseUpdate(const std::string& current);
}
