-- Translate data only. Never import listeners, scripts, DNS, executable rules,
-- local paths or arbitrary remote providers from a subscription.
local json=require('luci.jsonc')
local M={}
function M.parse(data,fetch)
    assert(type(data)=='string' and #data<=2097152,'规则订阅超过 2MB')
    local root=json.parse(data)
    if not root then local ok,v=pcall(require('lyaml').load,data);if ok then root=v end end
    if type(root)=='table' and type(root.route)=='table' then root={rules=root.route.rules} end
    local out,skipped={},0
    local providers=type(root)=='table' and root['rule-providers'] or {}
    local fetched,total,bytes={},0,0
    local function add(r,target)
        r.target=target=='DIRECT' and 'direct' or (target=='REJECT' or target=='REJECT-DROP') and 'reject' or 'proxy'
        out[#out+1]=r;assert(#out<=12000,'最多导入 12000 条规则')
    end
    local line
    line=function(s,target)
        if type(s)~='string' or #s>1024 or s:find('%c') then skipped=skipped+1;return end
        local p={};for v in (s..','):gmatch('(.-),') do p[#p+1]=v:match('^%s*(.-)%s*$') end
        local k,v=p[1]:upper(),p[2];target=target or p[3] or 'PROXY'
        local field=({DOMAIN='domain',['DOMAIN-SUFFIX']='domain_suffix',['DOMAIN-KEYWORD']='domain_keyword',['IP-CIDR']='ip_cidr',['IP-CIDR6']='ip_cidr'})[k]
        if field and v and v~='' then add({[field]={v}},target)
        elseif (k=='GEOIP' or k=='GEOSITE') and v and v:upper()=='CN' then add({rule_set={k=='GEOIP' and 'geoip-cn' or 'geosite-cn'}},target)
        elseif k=='RULE-SET' and fetch and type(providers)=='table' and type(providers[v])=='table' then
            local provider=providers[v]
            local behavior=provider.behavior
            if provider.type~='http' or type(provider.url)~='string' or not provider.url:match('^https://') or (behavior~='domain' and behavior~='ipcidr' and behavior~='classical') or provider.format=='mrs' then skipped=skipped+1;return end
            local payload=fetched[v]
            if not payload then
                total=total+1;assert(total<=16,'外部规则提供器最多 16 个')
                local raw=fetch(provider.url);bytes=bytes+#raw;assert(bytes<=8388608,'外部规则累计下载超过 8MB');local parsed=json.parse(raw)
                if not parsed then local ok,x=pcall(require('lyaml').load,raw);if ok then parsed=x end end
                payload=type(parsed)=='table' and parsed.payload
                if type(payload)~='table' and provider.format=='text' then payload={};for x in raw:gmatch('[^\r\n]+') do if not x:match('^%s*[#!]') then payload[#payload+1]=x end end end
                assert(type(payload)=='table','规则提供器格式无效，原设置保留');assert(#payload<=12000,'单个规则提供器最多 12000 项')
                fetched[v]=payload
            end
            local suffix,exact,ips={},{},{}
            for _,x in ipairs(payload) do
                if type(x)~='string' or #x>253 or x:find('%c') then skipped=skipped+1
                elseif behavior=='classical' then if x:match('^%s*RULE%-SET') then skipped=skipped+1 else line(x,target) end
                elseif behavior=='ipcidr' then ips[#ips+1]=x
                elseif x:sub(1,2)=='+.' then suffix[#suffix+1]=x:sub(3)
                elseif x:sub(1,2)=='*.' then suffix[#suffix+1]=x:sub(3)
                elseif x:sub(1,1)=='.' then suffix[#suffix+1]=x:sub(2)
                elseif x:find('*',1,true) then skipped=skipped+1
                else exact[#exact+1]=x end
            end
            if #suffix>0 or #exact>0 or #ips>0 then add({domain_suffix=#suffix>0 and suffix or nil,domain=#exact>0 and exact or nil,ip_cidr=#ips>0 and ips or nil},target) end
        elseif k=='MATCH' or k=='FINAL' then add({},p[2] or target)
        else skipped=skipped+1 end
    end
    if type(root)=='table' and type(root.rules)=='table' then
        for _,r in ipairs(root.rules) do
            if type(r)=='string' then line(r)
            elseif type(r)=='table' then
                local clean,valid={},true
                local allow={domain=true,domain_suffix=true,domain_keyword=true,ip_cidr=true}
                for k,v in pairs(r) do
                    if allow[k] then
                        if type(v)=='string' then v={v} end
                        if type(v)~='table' or #v==0 then valid=false else
                            clean[k]={};for _,x in ipairs(v) do if type(x)~='string' or #x>253 or x:find('%c') then valid=false else table.insert(clean[k],x) end end
                        end
                    elseif k~='outbound' and k~='action' then valid=false end
                end
                if r.action and r.action~='route' and r.action~='reject' then valid=false end
                if valid then add(clean,r.action=='reject' and 'REJECT' or r.outbound=='direct' and 'DIRECT' or 'PROXY') else skipped=skipped+1 end
            else skipped=skipped+1 end
        end
    elseif type(root)=='table' and type(root.payload)=='table' then
        for _,r in ipairs(root.payload) do line(r,'DIRECT') end
    elseif type(root)=='table' or data:find('://',1,true) or data:match('^%s*[%w+/=]+%s*$') then
        return {},0 -- Node-only URI/Base64 subscriptions contain no rules.
    else
        for r in data:gmatch('[^\r\n]+') do if not r:match('^%s*[#!]') and r:find(',',1,true) then line(r) end end
    end
    return out,skipped
end
return M
