#pragma once
#include <algorithm>
#include <cmath>

namespace shodan {
// Analytic critically damped motion. Preserve position on a reversed target,
// and keep the visual inside its old/target interval so layouts never overshoot.
inline bool damped(float& value,float& velocity,float target,float dt,float rate=24.0f){
 dt=std::clamp(dt,0.0f,0.05f);
 const float old=value,delta=value-target,mixed=velocity+rate*delta;
 const float decay=std::exp(-rate*dt);
 value=target+(delta+mixed*dt)*decay;
 velocity=(velocity-rate*mixed*dt)*decay;
 const float bounded=std::clamp(value,std::min(old,target),std::max(old,target));
 if(bounded!=value){value=bounded;velocity=0;}
 if(std::abs(value-target)<0.001f&&std::abs(velocity)<0.015f){value=target;velocity=0;return false;}
 return true;
}
}
