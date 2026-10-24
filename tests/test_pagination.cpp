#include "pagination.h"
#include <cassert>
#include <limits>
int main(){
 double remainder=0;
 assert(pageWithWheel(0,7,-1,remainder)==1);
 assert(pageWithWheel(3,7,1,remainder)==2);
 assert(pageWithWheel(0,7,1,remainder)==0);
 assert(pageWithWheel(6,7,-8,remainder)==6);
 assert(pageWithWheel(0,0,-1,remainder)==0);
 remainder=0;
 assert(pageWithWheel(2,7,-0.4,remainder)==2);
 assert(pageWithWheel(2,7,-0.4,remainder)==2);
 assert(pageWithWheel(2,7,-0.4,remainder)==3);
 assert(pageWithWheel(3,7,std::numeric_limits<double>::quiet_NaN(),remainder)==3);
}
