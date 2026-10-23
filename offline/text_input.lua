-- Unicode input collected from this application's Windows message queue.
local M={queue={},high=nil}
local function utf8(c)
    if c<128 then return string.char(c) end
    if c<2048 then return string.char(192+math.floor(c/64),128+c%64) end
    if c<65536 then return string.char(224+math.floor(c/4096),128+math.floor(c/64)%64,128+c%64) end
    return string.char(240+math.floor(c/262144),128+math.floor(c/4096)%64,128+math.floor(c/64)%64,128+c%64)
end
function M.push(code)
    if code>=0xD800 and code<=0xDBFF then M.high=code;return end
    if code>=0xDC00 and code<=0xDFFF then
        if not M.high then return end
        code=65536+(M.high-0xD800)*1024+code-0xDC00
    end
    M.high=nil
    if code==8 then M.queue[#M.queue+1]={kind='backspace'}
    elseif code==13 then M.queue[#M.queue+1]={kind='enter'}
    elseif code>=32 and code~=127 then M.queue[#M.queue+1]={kind='text',text=utf8(code)} end
end
function M.paste(text)
    text=tostring(text or ''):gsub('[%z\1-\31\127]','')
    if text~='' then M.queue[#M.queue+1]={kind='text',text=text} end
end
function M.take() local queue=M.queue;M.queue={};return queue end
return M
