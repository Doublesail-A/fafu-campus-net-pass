-- Subscription data is parsed, never executed. Import nodes only, not remote
-- inbounds, routes, DNS, rule sets, local file paths or shell commands.
local json=require('luci.jsonc')
local bin=require('nixio').bin
local M={}
local function decode(s)
    return (s or ''):gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
end
local function b64(s)
    s=s:gsub('%s',''):gsub('-','+'):gsub('_','/')
    s=s..string.rep('=',(4-#s%4)%4)
    local ok,v=pcall(bin.b64decode,s); return ok and v or nil
end
local function pick(t,keys)
    local out={}; if type(t)~='table' then return out end
    for key in keys:gmatch('%S+') do
        local v=t[key]
        if type(v)=='string' or type(v)=='number' or type(v)=='boolean' then out[key]=v end
    end
    return out
end
local function native(n)
    if type(n)~='table' then return nil end
    local supported={anytls=true,ss=true,shadowsocks=true,vmess=true,vless=true,trojan=true,hysteria2=true,tuic=true,socks=true,http=true}
    if not supported[n.type] then return nil end
    local out=pick(n,'type tag server server_port password uuid method security alter_id flow network username version zero_rtt congestion_control heartbeat up_mbps down_mbps')
    if out.type=='ss' then out.type='shadowsocks' end
    if type(n.tls)=='table' then
        out.tls=pick(n.tls,'enabled server_name insecure disable_sni min_version max_version')
        if type(n.tls.alpn)=='table' then out.tls.alpn=n.tls.alpn end
        if n.tls.utls then out.tls.utls=pick(n.tls.utls,'enabled fingerprint') end
        if n.tls.reality then out.tls.reality=pick(n.tls.reality,'enabled public_key short_id') end
    end
    if type(n.transport)=='table' then
        out.transport=pick(n.transport,'type path host service_name early_data_header_name max_early_data')
        if type(n.transport.headers)=='table' then out.transport.headers=pick(n.transport.headers,'Host User-Agent') end
    end
    if type(n.obfs)=='table' then out.obfs=pick(n.obfs,'type password') end
    return out
end
local function tls(n,q,default)
    local on=default or q.security=='tls' or q.security=='reality' or q.tls=='tls'
    if on then
        n.tls={enabled=true,server_name=q.sni or q.peer or n.server,insecure=q.insecure=='1' or q.allowInsecure=='1'}
        if q.fp and q.fp~='' then n.tls.utls={enabled=true,fingerprint=q.fp} end
        if q.security=='reality' then n.tls.reality={enabled=true,public_key=q.pbk,short_id=q.sid or ''} end
        if q.alpn then n.tls.alpn={};for a in q.alpn:gmatch('[^,]+') do table.insert(n.tls.alpn,a) end end
    end
    local t=q.type or q.network
    if t=='ws' then n.transport={type='ws',path=q.path or '/',headers={Host=q.host or q.sni or n.server}}
    elseif t=='grpc' then n.transport={type='grpc',service_name=q.serviceName or ''}
    elseif t and t~='tcp' and t~='none' then return nil end
    return n
end
local function uri(line)
    local kind,rest=line:match('^([%w]+)://(.+)$'); if not kind then return nil end
    kind=kind:lower(); if kind=='hy2' then kind='hysteria2' end
    if kind=='vmess' then
        local v=json.parse(b64(rest) or '')
        if type(v)~='table' then return nil end
        local n={type='vmess',tag=v.ps,server=v.add,server_port=tonumber(v.port),uuid=v.id,security=v.scy or 'auto',alter_id=tonumber(v.aid) or 0}
        return tls(n,{tls=v.tls,sni=v.sni,host=v.host,path=v.path,type=v.net},false)
    end
    local body,name=rest:match('^(.-)#(.*)$'); body=body or rest
    local authority,query=body:match('^(.-)%?(.*)$'); authority=authority or body
    local q={};for k,v in (query or ''):gmatch('([^&=]+)=([^&]*)') do q[decode(k)]=decode(v) end
    authority=authority:gsub('/$','')
    if kind=='ss' and not authority:find('@',1,true) then authority=b64(authority) or '' end
    local user,host=authority:match('^(.*)@([^@]+)$'); if not host then return nil end
    local server,port=host:match('^%[([^%]]+)%]:(%d+)$')
    if not server then server,port=host:match('^([^:/]+):(%d+)') end
    local n={type=kind,tag=decode(name or ''),server=server,server_port=tonumber(port)}
    user=decode(user)
    if kind=='ss' then
        if not user:find(':',1,true) then user=b64(user) or '' end
        n.type='shadowsocks';n.method,n.password=user:match('^([^:]+):(.*)$')
        if q.plugin then return nil end -- unsupported plugins are not silently removed
        return n
    elseif kind=='vless' then n.uuid=user;n.flow=q.flow
    elseif kind=='tuic' then n.uuid,n.password=user:match('^([^:]+):(.*)$');n.congestion_control=q.congestion_control
    elseif kind=='socks' or kind=='http' then n.username,n.password=user:match('^([^:]+):(.*)$');return n
    else n.password=user end
    if kind=='hysteria2' and q.obfs then n.obfs={type=q.obfs,password=q['obfs-password']} end
    return tls(n,q,kind=='anytls' or kind=='trojan' or kind=='hysteria2' or kind=='tuic')
end
local function clash(v)
    if type(v)~='table' then return nil end
    local n={type=v.type,tag=v.name,server=v.server,server_port=v.port,password=v.password,uuid=v.uuid,username=v.username,flow=v.flow}
    if n.type=='ss' then n.type='shadowsocks';n.method=v.cipher;if v.plugin then return nil end end
    if n.type=='vmess' then n.security=v.cipher or 'auto';n.alter_id=tonumber(v.alterId) or 0 end
    if n.type=='hysteria2' and v.obfs then n.obfs={type=v.obfs,password=v['obfs-password']} end
    if n.type=='tuic' then n.congestion_control=v['congestion-controller'] end
    local need=v.tls or n.type=='anytls' or n.type=='trojan' or n.type=='hysteria2' or n.type=='tuic'
    if need then
        n.tls={enabled=true,server_name=v.servername or v.sni or v.server,insecure=v['skip-cert-verify']==true,alpn=v.alpn}
        if v['client-fingerprint'] then n.tls.utls={enabled=true,fingerprint=v['client-fingerprint']} end
        if v['reality-opts'] then n.tls.reality={enabled=true,public_key=v['reality-opts']['public-key'],short_id=v['reality-opts']['short-id'] or ''} end
    end
    if v.network=='ws' then local w=v['ws-opts'] or {};n.transport={type='ws',path=w.path or '/',headers=w.headers or {}}
    elseif v.network=='grpc' then n.transport={type='grpc',service_name=(v['grpc-opts'] or {})['grpc-service-name'] or ''}
    elseif v.network and v.network~='tcp' then return nil end
    return native(n)
end
function M.parse(data,filter)
    assert(type(data)=='string' and #data<=2097152,'订阅超过 2MB 或内容无效')
    local root=json.parse(data)
    if not root and not data:find('://',1,true) and not data:match('^%s*proxies:') then
        local decoded=b64(data);if decoded then data=decoded;root=json.parse(data) end
    end
    local candidates={};local skipped=0
    if type(root)=='table' then
        local nodes=root.outbounds or root.proxies or root
        for _,v in ipairs(nodes) do local n=root.proxies and clash(v) or native(v);if n then table.insert(candidates,n) else skipped=skipped+1 end end
    elseif data:find('proxies%s*:') then
        local ok,v=pcall(require('lyaml').load,data)
        assert(ok and type(v)=='table' and type(v.proxies)=='table','Clash YAML 格式无效')
        for _,node in ipairs(v.proxies) do local n=clash(node);if n then table.insert(candidates,n) else skipped=skipped+1 end end
    else
        for line in data:gmatch('[^\r\n]+') do if line:match('://') then local n=uri(line);n=n and native(n);if n then table.insert(candidates,n) else skipped=skipped+1 end end end
    end
    local out,used={},{}
    for i,n in ipairs(candidates) do
        n.server_port=tonumber(n.server_port)
        local name=n.tag or ('节点 '..i)
        local keep=filter==''
        for word in (filter or ''):gmatch('[^|]+') do if name:lower():find(word:lower(),1,true) then keep=true end end
        if keep and type(n.server)=='string' and n.server~='' and not n.server:find('[%c%s]') and n.server_port and n.server_port>=1 and n.server_port<=65535 then
            name=name:gsub('%c',' '):sub(1,160); if name=='' then name='节点 '..i end
            if name=='direct' or name:match('^privacy%-') then name='节点 '..name end
            local base=name;local suffix=1;while used[name] do suffix=suffix+1;name=base..' ('..suffix..')' end
            used[name]=true;n.tag=name;n.routing_mark=201;table.insert(out,n)
        end
    end
    assert(#out>0,'订阅中没有受支持且匹配筛选条件的节点；保留现有配置')
    assert(#out<=300,'最多导入 300 个节点，请缩小名称筛选范围')
    return out,skipped
end
M.native=native
return M
