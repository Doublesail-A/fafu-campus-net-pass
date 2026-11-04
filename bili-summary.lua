local fs=require('nixio.fs');local j=require('luci.jsonc');local dir=arg[1]
local function read(p)return assert(fs.readfile(dir..'/'..p))end
local function percentile(list,p)table.sort(list);return list[math.max(1,math.ceil(#list*p))]end
local totals,dns,tls,first={}, {},{},{};local failures,bytes,h2=0,0,0
for path in fs.glob(dir..'/*.txt')do
 local s=assert(fs.readfile(path));local code,d,c,a,f,t,size,version=s:match('(%d+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+)')
 if not code or tonumber(code)>=400 or tonumber(code)==0 then failures=failures+1 end
 if code then totals[#totals+1]=tonumber(t);dns[#dns+1]=tonumber(d);tls[#tls+1]=tonumber(a)-tonumber(c);first[#first+1]=tonumber(f);bytes=bytes+tonumber(size);if version=='2'then h2=h2+1 end end
end
local function ticks(s)local n={};for w in s:gmatch('%S+')do n[#n+1]=w end;return tonumber(n[14])+tonumber(n[15])end
local function hits(s)return tonumber(s:match('counter packets (%d+) bytes %d+ redirect to :1080')) or 0 end
for path in fs.glob(dir..'/*.err')do if (fs.stat(path) or {}).size and fs.stat(path).size>0 then failures=failures+1 end end
local result={requests=#totals,failures=failures,bytes=bytes,h2=h2,batch=tonumber(read('end'))-tonumber(read('start')),median=percentile(totals,.5),p95=percentile(totals,.95),dns_p95=percentile(dns,.95),tls_p95=percentile(tls,.95),ttfb_p95=percentile(first,.95),ua3f_ticks=ticks(read('ua-after'))-ticks(read('ua-before')),ua3f_new=hits(read('nft-after'))-hits(read('nft-before'))}
fs.writefile(dir..'/summary.json',j.stringify(result));print(dir:match('[^/]+$')..' '..j.stringify(result))
assert(#totals>0 and failures==0,'HTTP transfer failures: inspect per-resource errors')
