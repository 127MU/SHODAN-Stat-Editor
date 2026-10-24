#include "search.h"
#include <cassert>
#include <cmath>
int main(){
 using namespace shodan;
 assert(compactSearch("AR-11 Liberator")=="ar11liberator");
 assert(initials("解放者")=="jfz");
 auto index=searchIndex("AR-23 解放者 Liberator")+" "+searchIndex("0123ABCD");
 assert(searchMatches(index,"ar23"));assert(searchMatches(index,"jfz"));
 assert(searchMatches(index,"LIBERATOR"));assert(searchMatches(index,"ar23 jfz"));
 assert(!searchMatches(index,"ar23 unknown"));
 for(int cols:{1,2,4})for(float viewport:{160.0f,500.0f,900.0f})for(float a:{0.0f,132.0f,1800.0f})for(float b:{0.0f,800.0f,3000.0f}){
  auto r=visibleRange(100,cols,44,viewport,a,b);assert(r.first>=0&&r.end<=100&&r.first<=r.end);
  for(float y:{a,b})for(int i=0;i<100;++i){float top=(i/cols)*44.0f;
   if(top+44>=y&&top<=y+viewport)assert(i>=r.first&&i<r.end);
  }
 }
 auto empty=visibleRange(0,1,44,500,0,0);assert(empty.first==empty.end);
}
