#include "../desktop/eui/motion.h"
#include <cassert>
#include <cmath>
#include <iostream>

float advance(int fps){
 float value=0,velocity=0;
 for(int i=0;i<fps/2;++i){float before=value;shodan::damped(value,velocity,1,1.0f/fps);assert(value>=before&&value<=1);}
 return value;
}
int main(){
 const float a=advance(30),b=advance(60),c=advance(144);
 assert(std::abs(a-b)<0.001f&&std::abs(b-c)<0.001f&&c>0.999f);
 float value=0,velocity=0;
 for(int i=0;i<1000;++i){
  const float target=(i/7)%2?1:0,old=value;
  shodan::damped(value,velocity,target,1.0f/120);
  assert(std::isfinite(value)&&std::isfinite(velocity));
  assert(value>=0&&value<=1);
  assert(value>=std::min(old,target)&&value<=std::max(old,target));
 }
 const float before=value;shodan::damped(value,velocity,1,0);assert(value==before);
 std::cout<<"Motion: frame-rate independent, bounded, continuous on rapid reversals.\n";
}
