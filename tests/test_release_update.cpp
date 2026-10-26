#include "release_update.h"
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <fstream>
#include <sstream>
int main(int argc,char** argv){
 if(argc>1&&std::string(argv[1])=="--live"){
  auto r=shodan::checkReleaseUpdate("4.1.0-r5");std::cout<<r.version<<"\n"<<r.url<<"\n"<<r.error<<"\nnotes bytes="<<r.notes.size()<<"\n"<<r.downloadUrl<<"\n";return r.error.empty()?0:1;
 }
 if(argc==4&&std::string(argv[1])=="--public-files"){
  auto read=[](const char* p){std::ifstream f(p);std::ostringstream s;s<<f.rdbuf();return s.str();};
  auto notes=shodan::releaseNotesFromFeed(read(argv[2]),"v4.1.0-r20");auto url=shodan::releaseDownloadFromAssets(read(argv[3]),"v4.1.0-r20");
  assert(notes.find("资源")!=std::string::npos);assert(url=="https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.1.0-r20/SHODAN_4.1.0-r20.exe");
  std::cout<<"actual public feed notes bytes="<<notes.size()<<"\n"<<url<<"\n";return 0;
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
 auto web=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){++requests;return api?shodan::ReleaseResponse{403,{},{}}:shodan::ReleaseResponse{302,{},"/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"};});
 assert(web.newer&&web.error.empty()&&requests==2&&!web.notes.empty());
 requests=0;
 auto same=shodan::checkReleaseUpdate("4.1.0-r9",[&](bool api){++requests;assert(!api);return shodan::ReleaseResponse{302,{},"/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"};});
 assert(!same.newer&&requests==1);
 const std::string detailed=R"({"draft":false,"prerelease":false,"tag_name":"v4.1.0-r9","html_url":"https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9","body":"## Changes\n- Fix startup","assets":[{"name":"bad.exe","browser_download_url":"https://example.com/bad.exe"},{"name":"SHODAN_4.1.0-r9.exe","browser_download_url":"https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.1.0-r9/SHODAN_4.1.0-r9.exe"}]})";
 requests=0;
 auto detail=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){++requests;return api?shodan::ReleaseResponse{200,detailed,{}}:shodan::ReleaseResponse{302,{},"/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"};});
 assert(detail.newer&&detail.notes=="## Changes\n- Fix startup"&&detail.downloadUrl=="https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.1.0-r9/SHODAN_4.1.0-r9.exe"&&requests==2);
 const std::string atom=R"(<feed><entry><link href="https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"/><content type="html">&lt;h3&gt;修复内容&lt;/h3&gt;&lt;ul&gt;&lt;li&gt;修复 &amp;amp; 更新&lt;/li&gt;&lt;/ul&gt;</content></entry></feed>)";
 const std::string assets=R"(<a href="https://example.com/bad.exe">bad</a><a href="/127MU/SHODAN-Stat-Editor/releases/download/v4.1.0-r9/SHODAN_4.1.0-r9.exe">download</a>)";
 int publicRequests=0;
 auto limited=shodan::checkReleaseUpdate("4.1.0-r8",[&](bool api){return api?shodan::ReleaseResponse{403,{},{}}:shodan::ReleaseResponse{302,{},"/127MU/SHODAN-Stat-Editor/releases/tag/v4.1.0-r9"};},[&](const std::string& path){++publicRequests;return shodan::ReleaseResponse{200,path.find(".atom")!=std::string::npos?atom:assets,{}};});
 assert(limited.newer&&limited.notes.find("修复 & 更新")!=std::string::npos&&!limited.downloadUrl.empty()&&publicRequests==2);
 assert(shodan::releaseNotesFromFeed(atom,"v4.1.0-r8").empty());
 assert(shodan::releaseDownloadFromAssets(assets,"v4.1.0-r8").empty());
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
