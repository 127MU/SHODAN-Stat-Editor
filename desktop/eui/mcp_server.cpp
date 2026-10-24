#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include "mcp_server.h"
#include <yyjson.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <stdexcept>
namespace shodan {
Value object(std::initializer_list<std::pair<const std::string,Value>> fields){Value v;v.kind=Value::Table;v.fields=fields;return v;}
namespace {
const char* alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
std::string base64(const std::string& s){std::string out;unsigned v=0;int bits=-6;for(unsigned char c:s){v=(v<<8)|c;bits+=8;while(bits>=0){out+=alphabet[(v>>bits)&63];bits-=6;}}if(bits>-6)out+=alphabet[((v<<8)>>(bits+8))&63];while(out.size()%4)out+='=';return out;}
std::string unbase64(const std::string& s){if(s.size()%4)throw std::runtime_error("Invalid base64 length");std::string out;unsigned v=0;int bits=-8;bool pad=false;size_t pads=0;for(unsigned char c:s){if(c=='='){pad=true;if(++pads>2)throw std::runtime_error("Invalid base64 padding");continue;}const char* p=std::strchr(alphabet,c);if(!p||!c||pad)throw std::runtime_error("Invalid base64 data");v=(v<<6)|unsigned(p-alphabet);bits+=6;if(bits>=0){out+=char((v>>bits)&255);bits-=8;}}return out;}
Value decode(yyjson_val* v,int depth){if(depth>24)throw std::runtime_error("JSON nesting limit");Value out;
 if(yyjson_is_str(v))return Value(std::string(yyjson_get_str(v),yyjson_get_len(v)));
 if(yyjson_is_bool(v))return Value(yyjson_get_bool(v));if(yyjson_is_num(v))return Value(yyjson_get_num(v));
 if(yyjson_is_arr(v)){out.kind=Value::Table;out.arrayValue=true;size_t i,n;yyjson_val* item;yyjson_arr_foreach(v,i,n,item)out.array.push_back(decode(item,depth+1));}
 if(yyjson_is_obj(v)){out.kind=Value::Table;size_t i,n;yyjson_val *key,*item;yyjson_obj_foreach(v,i,n,key,item)out.fields[std::string(yyjson_get_str(key),yyjson_get_len(key))]=decode(item,depth+1);
  if(out.fields.size()==1&&out["$base64"].kind==Value::String)return Value(unbase64(out["$base64"].str()));}
 return out;
}
bool equalSecret(const std::string& a,const std::string& b){unsigned diff=unsigned(a.size()^b.size());for(size_t i=0;i<b.size();++i)diff|=unsigned((i<a.size()?a[i]:0)^b[i]);return diff==0;}
std::string lower(std::string s){for(char& c:s)c=char(std::tolower(static_cast<unsigned char>(c)));return s;}
void sendAll(SOCKET c,const std::string& s){size_t at=0;while(at<s.size()){int n=send(c,s.data()+at,int(std::min(size_t(65536),s.size()-at)),0);if(n<=0)return;at+=n;}}
void reply(SOCKET c,int code,const std::string& body){std::string reason=code==200?"OK":code==202?"Accepted":code==401?"Unauthorized":code==403?"Forbidden":code==405?"Method Not Allowed":code==413?"Content Too Large":"Bad Request";
 sendAll(c,"HTTP/1.1 "+std::to_string(code)+" "+reason+"\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: "+std::to_string(body.size())+"\r\n\r\n"+body);}
void closeConnection(SOCKET c){
 // A rejection may precede the client's request body. Closing a WinSock socket
 // with unread bytes sends RST and can discard the HTTP error response.
 shutdown(c,SD_SEND);char buffer[4096];size_t drained=0;int n=0;
 while(drained<8*1024*1024&&(n=recv(c,buffer,sizeof buffer,0))>0)drained+=size_t(n);
 closesocket(c);
}
Value rpcError(const Value& id,int code,const std::string& message){return object({{"jsonrpc","2.0"},{"id",id},{"error",object({{"code",code},{"message",message}})}});}
}
Value jsonParse(const std::string& text){yyjson_read_err error{};auto* doc=yyjson_read_opts(const_cast<char*>(text.data()),text.size(),0,nullptr,&error);if(!doc)throw std::runtime_error("Invalid JSON");try{auto result=decode(yyjson_doc_get_root(doc),0);yyjson_doc_free(doc);return result;}catch(...){yyjson_doc_free(doc);throw;}}
std::string jsonEncode(const Value& value){
 auto quote=[](const std::string& s){std::string out="\"";const char* hex="0123456789abcdef";for(unsigned char c:s){if(c=='\"'||c=='\\'){out+='\\';out+=char(c);}else if(c<32){out+="\\u00";out+=hex[c>>4];out+=hex[c&15];}else out+=char(c);}return out+"\"";};
 std::function<std::string(const Value&,int)> write=[&](const Value& v,int depth)->std::string{
  if(depth>24)return "null";switch(v.kind){case Value::Nil:return "null";case Value::Boolean:return v.boolean?"true":"false";
  case Value::Number:{if(!std::isfinite(v.number))return "null";std::ostringstream stream;stream.imbue(std::locale::classic());stream<<std::setprecision(17)<<v.number;return stream.str();}
  case Value::String:{int n=v.text.empty()?0:MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,v.text.data(),int(v.text.size()),nullptr,0);
   if(v.text.find('\0')!=std::string::npos||(!v.text.empty()&&!n))return "{\"$base64\":"+quote(base64(v.text))+"}";return quote(v.text);}
  case Value::Table:{const bool array=v.arrayValue||!v.array.empty();std::string out=array?"[":"{";bool first=true;if(array)for(const auto& x:v.array){if(!first)out+=',';first=false;out+=write(x,depth+1);}else for(const auto& x:v.fields){if(!first)out+=',';first=false;out+=quote(x.first)+":"+write(x.second,depth+1);}return out+(array?"]":"}");}}
  return "null";
 };return write(value,0);
}
McpServer::~McpServer(){stop();}
void McpServer::record(const std::string& s){std::lock_guard<std::mutex> lock(mutex);history.push_back(s);while(history.size()>100)history.pop_front();}
Value McpServer::logs(){std::lock_guard<std::mutex> lock(mutex);Value v;v.kind=Value::Table;for(const auto& s:history)v.array.emplace_back(s);return v;}
std::string McpServer::endpoint()const{return "http://127.0.0.1:"+std::to_string(boundPort)+"/mcp";}
void McpServer::start(Value catalog,std::function<void()> notify){if(running)return;WSADATA data{};if(WSAStartup(MAKEWORD(2,2),&data))throw std::runtime_error("无法初始化 MCP 网络");
 SOCKET listener=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(listener==INVALID_SOCKET){WSACleanup();throw std::runtime_error("无法创建 MCP 端口");}
 sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=0;
 if(bind(listener,reinterpret_cast<sockaddr*>(&addr),sizeof addr)||listen(listener,8)){closesocket(listener);WSACleanup();throw std::runtime_error("无法监听 MCP 本地端口");}
 int len=sizeof addr;getsockname(listener,reinterpret_cast<sockaddr*>(&addr),&len);boundPort=ntohs(addr.sin_port);
 unsigned char random[32];if(BCryptGenRandom(nullptr,random,sizeof random,BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0){closesocket(listener);WSACleanup();throw std::runtime_error("无法生成 MCP 凭据");}
 secret.clear();const char* hex="0123456789abcdef";for(auto c:random){secret+=hex[c>>4];secret+=hex[c&15];}
 tools=std::move(catalog);wake=std::move(notify);running=true;
 try{worker=std::thread([this,listener]{serve(listener);closesocket(listener);WSACleanup();});}catch(...){running=false;closesocket(listener);WSACleanup();throw;}
 record("MCP enabled");
}
void McpServer::stop(){running=false;{std::lock_guard<std::mutex> lock(mutex);for(auto& p:pending)p->cancelled=true;pending.clear();}if(worker.joinable())worker.join();secret.clear();boundPort=0;}
std::shared_ptr<McpRequest> McpServer::take(){std::lock_guard<std::mutex> lock(mutex);while(!pending.empty()){auto p=pending.front();pending.pop_front();if(!p->cancelled)return p;}return {};}
void McpServer::serve(std::uintptr_t listenerValue){SOCKET listener=SOCKET(listenerValue);
 while(running){fd_set fds;FD_ZERO(&fds);FD_SET(listener,&fds);timeval wait{0,100000};if(select(0,&fds,nullptr,nullptr,&wait)<=0)continue;
 SOCKET c=accept(listener,nullptr,nullptr);if(c==INVALID_SOCKET)continue;DWORD timeout=1000;setsockopt(c,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<char*>(&timeout),sizeof timeout);setsockopt(c,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<char*>(&timeout),sizeof timeout);
 try{
  std::string raw;char buf[8192];size_t at=std::string::npos;while(running&&(at=raw.find("\r\n\r\n"))==std::string::npos){int n=recv(c,buf,sizeof buf,0);if(n<=0)break;raw.append(buf,n);if(raw.size()>16384)throw std::runtime_error("Header too large");}
  if(at==std::string::npos)throw std::runtime_error("Incomplete HTTP headers");
  std::istringstream headers(raw.substr(0,at));std::string line;std::getline(headers,line);std::istringstream first(line);std::string verb,path,version;first>>verb>>path>>version;
  std::map<std::string,std::string> h;while(std::getline(headers,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();auto colon=line.find(':');if(colon==std::string::npos)throw std::runtime_error("Invalid header");auto val=line.substr(colon+1);while(!val.empty()&&val.front()==' ')val.erase(val.begin());auto key=lower(line.substr(0,colon));if(h.count(key))throw std::runtime_error("Duplicate header");h[key]=val;}
  if(path!="/mcp"){reply(c,400,"{}");closeConnection(c);continue;}
  if(h.count("origin")&&h["origin"]!="http://127.0.0.1:"+std::to_string(boundPort)&&h["origin"]!="http://localhost:"+std::to_string(boundPort)){reply(c,403,"{}");closeConnection(c);continue;}
  if(!equalSecret(h["authorization"],"Bearer "+secret)){reply(c,401,"{}");closeConnection(c);continue;}
  if(verb!="POST"){reply(c,405,"{}");closeConnection(c);continue;}
  if(h.count("transfer-encoding")||h["content-type"].find("application/json")!=0)throw std::runtime_error("Expected JSON Content-Length body");
  auto lengthText=h["content-length"];if(lengthText.empty()||lengthText.find_first_not_of("0123456789")!=std::string::npos)throw std::runtime_error("Invalid content length");size_t size=std::stoull(lengthText);if(size>8*1024*1024){reply(c,413,"{}");closeConnection(c);continue;}
  std::string body=raw.substr(at+4);while(running&&body.size()<size){int n=recv(c,buf,int(std::min(sizeof buf,size-body.size())),0);if(n<=0)break;body.append(buf,n);}if(body.size()!=size)throw std::runtime_error("Incomplete HTTP body");
  Value request;try{request=jsonParse(body);}catch(...){reply(c,200,jsonEncode(rpcError({},-32700,"Parse error")));closeConnection(c);continue;}
  const auto id=request["id"];auto method=request["method"].str();if(request.kind!=Value::Table||request["jsonrpc"].str()!="2.0"||method.empty()){reply(c,200,jsonEncode(rpcError(id,-32600,"Invalid Request")));closeConnection(c);continue;}
  if(!request.fields.count("id")){reply(c,202,"");closeConnection(c);continue;}
  Value result;bool found=true;
  if(method=="initialize"){auto requested=request["params"]["protocolVersion"].str();if(requested!="2025-03-26"&&requested!="2025-06-18")requested="2025-11-25";
   result=object({{"protocolVersion",requested},{"capabilities",object({{"tools",object({{"listChanged",false}})}})},{"serverInfo",object({{"name","SHODAN Stat Editor"},{"version","4.0.0"}})},{"instructions","所有工具共享当前编辑器数据。先查询再修改，写入前关闭游戏。二进制字段使用 {\"$base64\":\"...\"}。"}});
  }else if(method=="ping")result=object({});
  else if(method=="tools/list")result=object({{"tools",tools}});
  else if(method=="tools/call"){
   auto task=std::make_shared<McpRequest>();task->name=request["params"]["name"].str();task->arguments=request["params"]["arguments"];auto future=task->response.get_future();
   {std::lock_guard<std::mutex> lock(mutex);pending.push_back(task);}wake();
   auto until=std::chrono::steady_clock::now()+std::chrono::minutes(5);
   while(running&&future.wait_for(std::chrono::milliseconds(100))!=std::future_status::ready&&std::chrono::steady_clock::now()<until){}
   Value output;bool error=false;if(future.wait_for(std::chrono::milliseconds(0))==std::future_status::ready){try{output=future.get();}catch(const std::exception& e){error=true;output=e.what();}}else{task->cancelled=true;error=true;output="请求超时或 MCP 已关闭；已开始的写入会安全完成，请查询状态确认。";}
   Value content;content.kind=Value::Table;content.array.push_back(object({{"type","text"},{"text",jsonEncode(output)}}));result=object({{"content",content},{"isError",error}});record(task->name+(error?" failed":" completed"));
  }else found=false;
  reply(c,200,jsonEncode(found?object({{"jsonrpc","2.0"},{"id",id},{"result",result}}):rpcError(id,-32601,"Method not found")));
 }catch(...){reply(c,400,"{}");}closeConnection(c);
 }
}
}
