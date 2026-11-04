print=function(...)local a={};for i=1,select('#',...)do a[#a+1]=tostring(select(i,...))end;io.stderr:write(table.concat(a,'\t'),'\n')end
SHODAN_EUI=true
package.path='app/?.lua;'..package.path
arg={'app/stat_editor.lua'}
API=assert(dofile('app/host.lua'))
local function quote(s)
 return '"'..s:gsub('[%z\1-\31\\"]',function(c)
  if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' end
  return string.format('\\u%04x',c:byte())
 end)..'"'
end
local function encode(v,depth,array,object)
 depth=depth or 0;assert(depth<30,'数据层级过深')
 local t=type(v)
 if t=='nil' then return 'null' elseif t=='boolean' then return tostring(v)
 elseif t=='number' then assert(v==v and math.abs(v)~=math.huge,'非有限数值');return string.format('%.17g',v)
 elseif t=='string' then return quote(v)
 elseif t=='table' then
  local out={};local n,count,dense=#v,0,true
  for k in pairs(v)do count=count+1;if type(k)~='number' or k%1~=0 or k<1 or k>n then dense=false end end
  if not object and (array or n>0 and dense and count==n) then for _,x in ipairs(v)do out[#out+1]=encode(x,depth+1)end;return '['..table.concat(out,',')..']' end
  for k,x in pairs(v)do if type(x)~='function' then out[#out+1]=quote(tostring(k))..':'..encode(x,depth+1,false,k=='enabled')end end
  return '{'..table.concat(out,',')..'}'
 end
 error('不支持的数据类型 '..t)
end
local arrays={items=true,rows=true,rows_fast=true,rows_section=true,shared=true,choices=true,full_presets=true,armor_rows=true,pending_preview=true}
SHODAN_EUI_PROGRESS=function(stage,done,total)
 if stage=='Installing: finding what changed...' then stage='正在核对修改内容'
 elseif stage=='Installing: writing the files...' then stage='正在写入游戏文件'
 else local file=stage:match('^Installing: preparing (.-) %(');if file then stage='准备并封装文件 · '..file end end
 io.stderr:write('@shodan-progress ',encode({stage=stage,done=done or 0,total=total or 0}),'\n');io.stderr:flush()
end
function invoke(method,args,count)
 if method=='info' then return encode({game=API.game,armor=API.armor_list,version='4.6.0'}) end
 assert(type(API[method])=='function','未提供接口：'..method)
 return encode(API[method](unpack(args,1,count or #args)),0,arrays[method])
end
