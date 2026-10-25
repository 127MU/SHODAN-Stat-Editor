#pragma once
#include <string>
#include <functional>
namespace shodan {
struct ReleaseUpdate {
 std::string version,url,error;
 bool newer=false;
 std::string notes,downloadUrl;
};
bool releaseNewer(const std::string& candidate,const std::string& current);
ReleaseUpdate parseReleaseUpdate(const std::string& json,const std::string& current);
struct ReleaseResponse {unsigned status=0;std::string body,location;};
using ReleaseFetch=std::function<ReleaseResponse(bool api)>;
ReleaseUpdate releaseFromLocation(const std::string& location,const std::string& current);
ReleaseUpdate checkReleaseUpdate(const std::string& current,const ReleaseFetch& fetch={});
}
