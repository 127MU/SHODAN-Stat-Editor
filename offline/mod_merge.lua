-- Sparse, baseline-relative merge. ZIP handling and export live in the desktop;
-- this module never writes game files or changes the editor's working buffers.
local ffi=require('ffi')
local bit=require('bit')
local G=require('gamedata')
local M={}
local MUL=0xC6A4A7935BD1E995ULL
local INV=0x5F7A0EA7E59B19BDULL
local SEED=16045690983977655786ULL
local function pointer(s)return ffi.cast('const uint8_t *',s)end
local function hash(s)return G.murmur64(pointer(s),#s)end
local function blocks(s)
 local p=pointer(s);local hs=G.headers(p,#s)
 assert(#hs>0,'无法识别数据容器')
 for _,h in ipairs(hs)do assert(h.at+24+h.size<=#s,'数据块越界');assert(p[h.at+16]==1,'不支持此数据块的指针宽度')end
 if hs[1].at==4 and G.u32(p,0)~=hs[1].type then
  assert(G.u32(p,0)==#hs,'设置表分组数量不匹配')
 end
 assert(hs[#hs].at+24+hs[#hs].size==#s,'不支持此文件的尾部布局')
 return hs
end
local function plain(raw)
 if raw:sub(1,4)=='LDLD' or raw:sub(5,8)=='LDLD' then blocks(raw);return raw end
 local p,n=G.open_sealed(raw);assert(p,'不能解封此 Mod，或它不是受支持的游戏数据文件')
 local s=ffi.string(p,n);G.free(p);blocks(s);return s
end
function M.tail(base,edits)
 local hs=blocks(base);local last=hs[#hs]
 local pad=(8-#base%8)%8;local size=#base+pad+8
 local p=ffi.new('uint8_t[?]',size);ffi.copy(p,base,#base)
 for off,edit in pairs(edits or {})do p[off]=edit.byte end
 ffi.cast('uint32_t *',p+last.at+12)[0]=last.size+pad+8
 local target=hash(base)
 local after=bit.bxor(target,bit.rshift(target,47))*INV
 after=bit.bxor(after,bit.rshift(after,47))
 local state=bit.bxor(SEED,(size+0ULL)*MUL)
 local words=ffi.cast('uint64_t *',p)
 for i=0,(size-8)/8-1 do state=bit.bxor(state,G.mix(words[i]))*MUL end
 words[(size-8)/8]=G.unmix(bit.bxor(after*INV,state))
 assert(G.murmur64(p,size)==target,'合并后的内容哈希校验失败')
 local result=ffi.string(p,size);blocks(result);return result
end
function M.merge(base,inputs,policy)
 assert(type(base)=='string' and #base>0,'缺少原版数据基准')
 assert(type(inputs)=='table' and #inputs>0,'没有可合并的输入')
 policy=policy or 'abort';assert(policy=='abort' or policy=='after','未知冲突策略')
 local hs=blocks(base);local bp=pointer(base);local target=hash(base)
 local masked={};for _,h in ipairs(hs)do for k=17,23 do masked[h.at+k]=true end end
 local edits,conflicts,details={},0,{}
 local result={mods={},conflicts=details,conflict_count=0,changed=0,hash=G.hex64(target)}
 for _,input in ipairs(inputs)do
  local label=tostring(input.label or 'Mod');local mod=plain(assert(input.data,'缺少 Mod 数据'))
  assert(#mod>=#base and #mod<=#base+23,label..'：文件长度不兼容，不能合并结构扩容的 Mod')
  assert(hash(mod)==target,label..'：内容哈希与原版不符，可能来自不同游戏版本')
  local mh=blocks(mod);assert(#mh==#hs,label..'：数据块数量不兼容')
  for i,h in ipairs(hs)do
   local expected=h.size+(i==#hs and #mod-#base or 0)
   assert(mh[i].at==h.at and mh[i].type==h.type and mh[i].size==expected,label..'：数据块布局不兼容')
  end
  local mp=pointer(mod);local count=0
  for off=0,#base-1 do
   if mp[off]~=bp[off] then
    local tailSize=off>=hs[#hs].at+12 and off<hs[#hs].at+16 and #mod>#base
    if not masked[off] and not tailSize then
     count=count+1;local existing=edits[off]
     if existing and existing.byte~=mp[off] then
      conflicts=conflicts+1
      if #details<80 then details[#details+1]={offset=off,before=existing.label,after=label,left=existing.byte,right=tonumber(mp[off])}end
      if policy=='after' then edits[off]={byte=tonumber(mp[off]),label=label}end
     elseif not existing then edits[off]={byte=tonumber(mp[off]),label=label}end
    end
   end
  end
  result.mods[#result.mods+1]={label=label,changed=count,tail=#mod-#base}
 end
 for _ in pairs(edits)do result.changed=result.changed+1 end
 result.conflict_count=conflicts
 if conflicts>0 and policy=='abort' then result.blocked=true;return result end
 local merged=M.tail(base,edits);local pp=pointer(merged)
 for off,edit in pairs(edits)do assert(pp[off]==edit.byte,'改动落地校验失败')end
 result.data=G.seal_string(merged)
 local verify=plain(result.data)
 assert(verify==merged and hash(verify)==target,'封装回读校验失败')
 result.bytes=#merged;result.blocked=false;return result
end
return M
