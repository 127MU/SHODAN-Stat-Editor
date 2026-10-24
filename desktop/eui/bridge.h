#pragma once
#include <map>
#include <memory>
#include <functional>
#include <string>
#include <vector>
struct lua_State;
struct Value {
 enum Kind { Nil, String, Number, Boolean, Table } kind=Nil;
 std::string text;
 double number=0;
 bool boolean=false;
 bool arrayValue=false;
 std::vector<Value> array;
 std::map<std::string,Value> fields;
 Value()=default;
 Value(const char* s):kind(String),text(s){}
 Value(std::string s):kind(String),text(std::move(s)){}
 Value(double n):kind(Number),number(n){}
 Value(int n):Value(double(n)){}
 Value(bool b):kind(Boolean),boolean(b){}
 const Value& operator[](const std::string& key) const {static Value empty;auto i=fields.find(key);return i==fields.end()?empty:i->second;}
 std::string str()const{return text;}
 int integer()const{return int(number);}
 bool yes()const{return boolean;}
};
class Backend {
 lua_State* L=nullptr;
 int api=0;
 Value read(int index,int depth=0);
 void push(const Value& value);
 static int progressThunk(lua_State* state);
public:
 std::function<void(const std::string&,int,int)> onProgress;
 std::map<std::string,std::vector<Value>> initialCatalog;
 std::map<int,std::vector<Value>> initialArmorValues;
 std::vector<Value> initialArmor;
 Backend();
 ~Backend();
 Backend(const Backend&)=delete;
 Value call(const char* method,const std::vector<Value>& args={});
 Value property(const char* name);
 Value interfaces();
 Value diagnostics();
};
