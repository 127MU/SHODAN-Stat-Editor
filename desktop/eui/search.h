#pragma once
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <sstream>
#include <string>

namespace shodan {
inline std::string compactSearch(std::string value){
 std::string out;
 for(unsigned char c:value){if(c>=128||std::isalnum(c))out+=char(c<128?std::tolower(c):c);}
 return out;
}
// GB2312 phonetic order covers common simplified Chinese. Unmappable characters
// remain searchable by their original spelling instead of inventing a reading.
inline std::string initials(const std::string& utf8){
 int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),int(utf8.size()),nullptr,0);
 if(!size)return {};
 std::wstring wide(size,0);MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8.data(),int(utf8.size()),wide.data(),size);
 constexpr int bounds[]={-20319,-20317,-19753,-19245,-18710,-18526,-18239,-17922,-17417,-16474,-16212,-15640,-15165,-14922,-14915,-14631,-14150,-14091,-13319,-12839,-12557,-11848,-11056};
 constexpr char letters[]="ABCDEFGHJKLMNOPQRSTWXYZ";
 std::string out;
 for(wchar_t c:wide){
  if(c<128){if(std::isalnum(static_cast<unsigned char>(c)))out+=char(std::tolower(static_cast<unsigned char>(c)));continue;}
  char bytes[8]{};BOOL fallback=FALSE;
  int n=WideCharToMultiByte(936,WC_NO_BEST_FIT_CHARS,&c,1,bytes,8,nullptr,&fallback);
  if(n!=2||fallback)continue;
  int value=int(static_cast<unsigned char>(bytes[0]))*256+static_cast<unsigned char>(bytes[1])-65536;
  if(value<bounds[0]||value>-10247)continue;
  int i=22;while(i>0&&value<bounds[i])--i;out+=char(std::tolower(letters[i]));
 }
 return out;
}
inline std::string searchIndex(const std::string& text){return compactSearch(text)+" "+initials(text);}
inline bool searchMatches(const std::string& index,const std::string& query){
 std::istringstream words(query);std::string word;
 while(words>>word){word=compactSearch(word);if(!word.empty()&&index.find(word)==std::string::npos)return false;}
 return true;
}
struct VisibleRange {int first=0,end=0;};
inline VisibleRange visibleRange(int count,int columns,float pitch,float viewport,float visual,float target){
 if(count<=0||columns<=0||pitch<=0||viewport<=0)return {};
 const float lo=std::max(0.0f,std::min(visual,target)),hi=std::max(visual,target);
 return {std::min(count,std::max(0,int(lo/pitch)-1)*columns),
  std::min(count,(int((hi+viewport)/pitch)+2)*columns)};
}
}
