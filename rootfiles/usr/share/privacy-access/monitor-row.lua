local j=require('luci.jsonc');local fs=require('nixio.fs')
local function read(p)return fs.readfile(p) or '' end
if arg[1]=='http' then
 local raw=j.parse(read(arg[2])) or {};local d={kind='http',probe_revision=3,epoch=tonumber(arg[3]),path=arg[4],target=arg[5],exit=tonumber(arg[6])}
 for _,k in ipairs({'http_code','time_namelookup','time_connect','time_appconnect','time_starttransfer','time_total','size_download','http_version','ssl_verify_result'})do d[k]=raw[k] end
 local body=read(arg[7]);d.page_ok=d.exit==0 and tonumber(raw.http_code)==200
 if d.target=='bilibili' then d.page_ok=d.page_ok and #body>10000 and (body:find('bilibili',1,true)~=nil or body:find('哔哩',1,true)~=nil) end
 if d.target=='bili-api' then local v=j.parse(body);d.app_code=v and v.code end
 print(j.stringify(d))
else
 local fields={kind='host',epoch=tonumber(arg[2]),load=read('/proc/loadavg'):gsub('\n',''),tcp=read('/proc/net/snmp'):match('Tcp: RtoAlgorithm.-\n(Tcp:[^\n]+)'),stat=read('/proc/stat'):match('^(cpu [^\n]+)')}
 for _,key in ipairs({'MemAvailable','SwapFree','Dirty'})do fields[key]=tonumber(read('/proc/meminfo'):match(key..':%s*(%d+)'))end
 fields.conntrack=tonumber(read('/proc/sys/net/netfilter/nf_conntrack_count'))
 local state=j.parse(read('/etc/privacy-proxy/settings.json')) or {};fields.selected=state.selected
 if arg[3] then local v=j.parse(read(arg[3]))or{};fields.selector_now=v.now end
 if arg[4] then local v=j.parse(read(arg[4]))or{};fields.auto_now=v.now end
 fields.cpu_ticks={};fields.pids={}
 for _,name in ipairs({'ua3f','squid','sing-box'})do
  local pipe=io.popen('pidof '..name);local ids=pipe and pipe:read('*a')or'';if pipe then pipe:close()end
  fields.pids[name]=ids:gsub('%s+$','');local total=0
  for pid in ids:gmatch('%d+')do local parts={};for x in read('/proc/'..pid..'/stat'):gmatch('%S+')do parts[#parts+1]=x end;total=total+(tonumber(parts[14])or 0)+(tonumber(parts[15])or 0)end
  fields.cpu_ticks[name]=total
 end
 print(j.stringify(fields))
end
