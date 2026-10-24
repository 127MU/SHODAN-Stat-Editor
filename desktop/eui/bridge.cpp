// In-process LuaJIT bridge. All callers must serialize access to this state.
#include "bridge.h"
#include <stdexcept>
#include <cstdio>
#include <filesystem>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "search.h"
extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}
namespace {
std::string luaError(lua_State* L){const char* s=lua_tostring(L,-1);return s?s:"Lua 后端返回了未知错误";}
}
int Backend::progressThunk(lua_State* state){
 auto* backend=static_cast<Backend*>(lua_touserdata(state,lua_upvalueindex(1)));
 if(backend&&backend->onProgress){
  const char* message=lua_tostring(state,1);
  backend->onProgress(message?message:"",int(lua_tonumber(state,2)),int(lua_tonumber(state,3)));
 }return 0;
}
Backend::Backend(){
 std::fprintf(stderr,"[startup] Lua backend starting\n");std::fflush(stderr);
 L=luaL_newstate();if(!L)throw std::runtime_error("LuaJIT 初始化失败");
 try {
  luaL_openlibs(L);lua_pushboolean(L,1);lua_setglobal(L,"SHODAN_EUI");
  lua_pushlightuserdata(L,this);lua_pushcclosure(L,progressThunk,1);lua_setglobal(L,"SHODAN_EUI_PROGRESS");
  wchar_t path[32768];GetModuleFileNameW(nullptr,path,32768);
  auto root=std::filesystem::path(path).parent_path();
  auto host=(root/"app"/"host.lua").generic_u8string();
  auto editor=(root/"app"/"stat_editor.lua").generic_u8string();
  lua_newtable(L);lua_pushstring(L,editor.c_str());lua_rawseti(L,-2,1);lua_setglobal(L,"arg");
  auto search=(root/"app"/"?.lua").generic_u8string();
  lua_getglobal(L,"package");lua_pushstring(L,search.c_str());lua_setfield(L,-2,"path");lua_pop(L,1);
  std::fprintf(stderr,"[startup] Loading host: %s\n",host.c_str());std::fflush(stderr);
  if(luaL_loadfile(L,host.c_str())||lua_pcall(L,0,1,0))throw std::runtime_error(luaError(L));
  if(!lua_istable(L,-1))throw std::runtime_error("后端未返回桌面接口");
  api=luaL_ref(L,LUA_REGISTRYINDEX);
  std::fprintf(stderr,"[startup] Host model ready\n");std::fflush(stderr);
  // Warm catalogs and armor metadata in the initialization worker. Page clicks
  // subsequently read these snapshots rather than rebuilding Lua record lists.
  for(const char* tab:{"Primary","Secondary","Support","Throwables","Stratagems","Mechas","Boosters","Attachments","Records","Helldiver","ArmorWeight","Terminids","Automatons","Illuminate","SEAF","Spawning"})
   {initialCatalog[tab]=call("items",{tab,""}).array;std::fprintf(stderr,"[startup] Catalog %s: %zu\n",tab,initialCatalog[tab].size());std::fflush(stderr);}
  for(auto& catalog:initialCatalog)for(auto& item:catalog.second){
   std::string index;
   for(const char* key:{"name","english","id","note","english_note"})index+=shodan::searchIndex(item[key].str())+" ";
   for(const auto& group:item["groups"].array)index+=shodan::searchIndex(group["name"].str())+" ";
   item.fields["search"]=Value(index);
  }
  std::fprintf(stderr,"[startup] Building armor metadata\n");std::fflush(stderr);
  initialArmor=property("armor_list").array;
  for(const auto& entry:initialArmor)
   initialArmorValues[entry["id"].integer()]=call("armor_rows",{entry["id"]}).array;
  std::fprintf(stderr,"[startup] Backend initialization complete\n");std::fflush(stderr);
 } catch(const std::exception& error) {std::fprintf(stderr,"[startup] Backend initialization failed: %s\n",error.what());std::fflush(stderr);lua_close(L);L=nullptr;throw;}
 catch(...) {std::fprintf(stderr,"[startup] Backend initialization failed (unknown)\n");std::fflush(stderr);lua_close(L);L=nullptr;throw;}
}
Backend::~Backend(){if(L){try{call("flush");}catch(...){}lua_close(L);}}
void Backend::push(const Value& v){
 switch(v.kind){case Value::String:lua_pushlstring(L,v.text.data(),v.text.size());break;
 case Value::Number:lua_pushnumber(L,v.number);break;case Value::Boolean:lua_pushboolean(L,v.boolean);break;
 case Value::Table:
  lua_newtable(L);
  for(size_t i=0;i<v.array.size();++i){push(v.array[i]);lua_rawseti(L,-2,int(i+1));}
  for(const auto& pair:v.fields){push(pair.second);lua_setfield(L,-2,pair.first.c_str());}
  break;
 default:lua_pushnil(L);}
}
Value Backend::read(int index,int depth){
 Value v;if(depth>12)return v;
 if(index<0)index=lua_gettop(L)+index+1;
 switch(lua_type(L,index)){
 case LUA_TSTRING:{size_t size=0;const char* data=lua_tolstring(L,index,&size);v.kind=Value::String;v.text.assign(data,size);break;}
 case LUA_TNUMBER:v.kind=Value::Number;v.number=lua_tonumber(L,index);break;
 case LUA_TBOOLEAN:v.kind=Value::Boolean;v.boolean=lua_toboolean(L,index)!=0;break;
 case LUA_TTABLE:{v.kind=Value::Table;
  size_t n=lua_objlen(L,index);v.array.reserve(n);
  for(size_t i=1;i<=n;++i){lua_rawgeti(L,index,int(i));v.array.push_back(read(-1,depth+1));lua_pop(L,1);}
  lua_pushnil(L);while(lua_next(L,index)){
   if(lua_type(L,-2)==LUA_TSTRING){
    const std::string key=lua_tostring(L,-2);auto item=read(-1,depth+1);
    if(item.kind==Value::Table&&(key=="help"||key=="shared"||key=="entries"||key=="files"||key=="problems"||key=="conflicts"||key=="warnings"))item.arrayValue=true;
    v.fields[key]=std::move(item);
   }
   else if(lua_type(L,-2)==LUA_TNUMBER)v.fields[std::to_string(int(lua_tonumber(L,-2)))]=read(-1,depth+1);
   lua_pop(L,1);
  }break;}
 default:break;
 }return v;
}
Value Backend::call(const char* method,const std::vector<Value>& args){
 int top=lua_gettop(L);lua_rawgeti(L,LUA_REGISTRYINDEX,api);lua_getfield(L,-1,method);lua_remove(L,-2);
 if(!lua_isfunction(L,-1)){lua_settop(L,top);throw std::runtime_error(std::string("未提供接口：")+method);}
 for(const auto& a:args)push(a);
 if(lua_pcall(L,int(args.size()),1,0)){auto err=luaError(L);lua_settop(L,top);throw std::runtime_error(err);}
 auto v=read(-1);lua_settop(L,top);
 const std::string name=method;
 if(v.kind==Value::Table&&(name=="items"||name=="rows"||name=="choices"||name=="shared"||name=="full_presets"||name=="armor_rows"||name=="pending_preview"))v.arrayValue=true;
 return v;
}
Value Backend::property(const char* name){
 int top=lua_gettop(L);lua_rawgeti(L,LUA_REGISTRYINDEX,api);lua_getfield(L,-1,name);
 auto v=read(-1);lua_settop(L,top);return v;
}
Value Backend::interfaces(){
 Value result;result.kind=Value::Table;int top=lua_gettop(L);
 lua_rawgeti(L,LUA_REGISTRYINDEX,api);lua_pushnil(L);
 while(lua_next(L,-2)){
  if(lua_type(L,-2)==LUA_TSTRING){Value item;item.kind=Value::Table;
   item.fields["name"]=lua_tostring(L,-2);item.fields["type"]=lua_typename(L,lua_type(L,-1));result.array.push_back(item);}
  lua_pop(L,1);
 }lua_settop(L,top);return result;
}
Value Backend::diagnostics(){
 Value result;result.kind=Value::Table;result.fields["lua_stack"]=lua_gettop(L);
 result.fields["lua_memory_kib"]=lua_gc(L,LUA_GCCOUNT,0);result.fields["interfaces"]=interfaces();
 result.fields["status"]=call("status");return result;
}
