#pragma once
#include <algorithm>
#include <cmath>

// GLFW wheel deltas may be fractional on touchpads. Preserve the remainder
// rather than dropping slow gestures, and never let paging leave its bounds.
inline int pageWithWheel(int page,int pages,double delta,double& remainder){
 pages=std::max(1,pages);page=std::clamp(page,0,pages-1);
 if(!std::isfinite(delta))return page;
 remainder=std::clamp(remainder+delta,-1000.0,1000.0);
 int steps=int(remainder);remainder-=steps;
 return std::clamp(page-steps,0,pages-1);
}
