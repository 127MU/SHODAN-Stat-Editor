local M={mode='light',cache={}}
function M.set(mode) M.mode=mode=='dark' and 'dark' or 'light' end
function M.color(c,text)
 if M.mode~='dark' then return c end
 local r,g,b=c[2],c[3],c[4]
 local key=(text and 't' or 'f')..r..':'..g..':'..b..':'..(c[1] or 255)
 if M.cache[key] then return M.cache[key] end
 local luminance=(r+g+b)/3
 local nr,ng,nb=r,g,b
 if text then
  if luminance<70 then nr,ng,nb=230,242,232
  elseif g>r*1.35 and g>b*1.12 then nr,ng,nb=98,235,175
  elseif r>g*1.3 and r>b*1.5 then nr,ng,nb=255,192,119
  elseif luminance<85 then nr,ng,nb=230,242,232
  elseif luminance<175 then nr,ng,nb=155,184,165 end
 else
  if (c[1] or 255)<255 and luminance<100 then nr,ng,nb=0,0,0
  elseif r==255 and g==255 and b==255 then nr,ng,nb=0,0,0
  elseif luminance>=247 then nr,ng,nb=0,0,0
  elseif luminance>=232 then nr,ng,nb=0,0,0
  elseif luminance>=210 then nr,ng,nb=0,0,0
  elseif luminance>=160 then nr,ng,nb=64,70,66
  elseif g>r*1.35 and g>b*1.12 and g<190 then nr,ng,nb=74,210,155 end
 end
 local mapped={c[1] or 255,nr,ng,nb};M.cache[key]=mapped;return mapped
end
return M
