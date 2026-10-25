#include "release_update.h"
#include <cassert>
#include <iostream>
#include <stdexcept>
int main(int argc,char** argv){
 if(argc>1&&std::string(argv[1])=="--live"){
  auto r=shodan::checkReleaseUpdate("4.1.0-r5");std::cout<<r.version<<"\n"<<r.url<<"\n"<<r.error<<"\n";return r.error.empty()?0:1;
 }
 using shodan::releaseNewer;using shodan::parseReleaseUpdate;
 assert(releaseNewer("v4.1.0-r5","4.1.0-r4"));
 assert(releaseNewer("v4.1.0-r10","4.1.0-r9"));
 assert(releaseNewer("v4.2.0","4.1.0-r100"));
 assert(!releaseNewer("v4.1.0-r4","4.1.0-r4"));
 assert(!releaseNewer("v4.1.0-r4","4.1.0-r5"));
 assert(!releaseNewer("dev","4.1.0-r5"));
 assert(!releaseNewer("v4.2.0-beta1","4.1.0-r5"));
 assert(!releaseNewer("v99999999999999999.0.0","4.1.0-r5"));
 auto json=[](const std::string& tag){return "{\"draft\":false,\"prerelease\":false,\"tag_name\":\""+tag+"\",\"html_url\":\"https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/"+tag+"\"}";};
 assert(parseReleaseUpdate(json("v4.1.0-r6"),"4.1.0-r5").newer);
 assert(!parseReleaseUpdate(json("v4.1.0-r5"),"4.1.0-r5").newer);
 assert(!parseReleaseUpdate(json("dev"),"4.1.0-r5").newer);
 auto pre=json("v4.2.0");pre.replace(pre.find("\"prerelease\":false"),18,"\"prerelease\":true");
 assert(!parseReleaseUpdate(pre,"4.1.0-r5").newer);
 auto draft=json("v4.2.0");draft.replace(draft.find("\"draft\":false"),13,"\"draft\":true");
 assert(!parseReleaseUpdate(draft,"4.1.0-r5").newer);
 assert(shodan::releaseFromLocation("/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9","4.1.0-r8").newer);
 assert(!shodan::releaseFromLocation("https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r8","4.1.0-r8").newer);
 for(const auto& location:{"https://example.com/releases/tag/v9999.0.0","https://github.com/other/project/releases/tag/v9999.0.0","/127MU/SHODAN-Stat-Editor/releases/tag/v4.2.0-beta1","/127MU/SHODAN-Stat-Editor/releases/tag/v4.2.0?redirect=1"}){
  bool rejected=false;try{shodan::releaseFromLocation(location,"4.1.0-r8");}catch(const std::runtime_error&){rejected=true;}assert(rejected);
 }
 int requests=0;
 auto web=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){++requests;assert(!api);return shodan::ReleaseResponse{302,{},"/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"};});
 assert(web.newer&&web.error.empty()&&requests==1);
 requests=0;
 auto fallback=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){++requests;return api?shodan::ReleaseResponse{200,json("v4.1.0-r9"),{}}:shodan::ReleaseResponse{503,{},{}};});
 assert(fallback.newer&&fallback.error.empty()&&requests==2);
 requests=0;
 auto unavailable=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){++requests;return shodan::ReleaseResponse{403,{},{}};});
 assert(!unavailable.error.empty()&&!unavailable.newer&&requests==2);
 for(const auto& bad:{std::string("not json"),std::string("{\"message\":\"API rate limit exceeded\"}"),std::string("[]"),std::string("{\"draft\":false,\"prerelease\":false,\"tag_name\":\"v4.2.0\",\"html_url\":\"https://example.com/\"}")}){
  bool rejected=false;try{parseReleaseUpdate(bad,"4.1.0-r5");}catch(const std::runtime_error&){rejected=true;}assert(rejected);
 }
 std::cout<<"release versions, revision ordering, published-only filtering, invalid response and project URL checks passed\n";
}
