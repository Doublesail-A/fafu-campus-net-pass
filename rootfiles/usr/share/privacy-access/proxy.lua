local fs=require('nixio.fs')
local json=require('luci.jsonc')
local util=require('luci.util')
local sys=require('luci.sys')
local parser=dofile('/usr/share/privacy-access/proxy-subscription.lua')
local policy=dofile('/usr/share/privacy-access/proxy-policy.lua')
local shared=dofile('/usr/share/privacy-access/proxy-shared.lua')
local rule_parser=dofile('/usr/share/privacy-access/proxy-rules.lua')
local DIR='/etc/privacy-proxy'
local STATE=DIR..'/settings.json'
local CONF='/etc/sing-box/privacy-iot.json'
local TEMP=DIR..'/devices'
local SQUID='/etc/squid/privacy-proxy.conf'
local API='http://127.0.0.1:9091'
local function passthrough()return (fs.readfile('/etc/privacy-transport-mode') or ''):match('^tls%-passthrough%-v1')~=nil end
local function quote(v)return util.shellquote(tostring(v))end
local function call(cmd)return sys.call(cmd..' 9>&-')==0 end
local function output(cmd)return sys.exec(cmd..' 9>&-')end
local function readjson(path)return json.parse(fs.readfile(path) or '')end
local function atomic(path,data)
    assert(fs.writefile(path..'.new',data),'无法写入配置')
    fs.chmod(path..'.new','600')
    assert(fs.rename(path..'.new',path),'无法替换配置')
end
local function state()return readjson(STATE) or {}end
local function save(s)atomic(STATE,json.stringify(s))end
local function conf()local c=readjson(CONF);assert(c and c.outbounds,'现有 sing-box 配置无法读取');return c end
local function secret()
    local path=DIR..'/api.secret'
    if not fs.readfile(path) then assert(call('openssl rand -hex 24 > '..quote(path)),'无法生成本地接口凭据');fs.chmod(path,'600') end
    return (fs.readfile(path) or ''):gsub('%s','')
end
local function api(path,method,body)
    assert(path:sub(1,1)=='/' and not path:find('[%c"\\]'),'接口路径无效')
    local header='header = "Authorization: Bearer '..secret()..'"\n'
    atomic('/tmp/privacy-proxy/api.curl',header)
    local cmd='curl --noproxy '..quote('*')..' --fail --silent --show-error --connect-timeout 2 --max-time 9 --config /tmp/privacy-proxy/api.curl '
    if method then cmd=cmd..' -X '..quote(method) end
    if body then atomic('/tmp/privacy-proxy/api.body',json.stringify(body));cmd=cmd..' -H '..quote('Content-Type: application/json')..' --data-binary @/tmp/privacy-proxy/api.body' end
    local data=output(cmd..' '..quote(API..path)..' 2>/dev/null')
    return json.parse(data),data
end
local function esc(s)return (s:gsub('([^%w%-_%.~])',function(c)return string.format('%%%02X',c:byte())end))end
local function peers(c)
    local list={};for _,n in ipairs(c.outbounds) do if n.server and n.server_port then table.insert(list,n) end end
    return list
end
local function generated(nodes,selected)
    local s=state()
    return policy.generate(nodes,selected,s.profiles or {},s.rules or {},secret(),fs.access(DIR..'/geosite-cn.srs') and fs.access(DIR..'/geoip-cn.srs'),passthrough())
end
local function install(c,squid)
    local old=assert(fs.readfile(CONF),'无法备份当前内核配置')
    local old_squid=fs.readfile(SQUID) or ''
    atomic('/tmp/privacy-proxy/candidate.json',json.stringify(c))
    assert(call('sing-box check -c /tmp/privacy-proxy/candidate.json >/tmp/privacy-proxy/check.log 2>&1'),'节点配置未通过内核校验，原配置保留')
    if squid then
        atomic(SQUID,squid)
        if not call('squid -k parse -f /etc/squid/squid.conf >/tmp/privacy-proxy/squid-check.log 2>&1') then atomic(SQUID,old_squid);error('HTTPS 配置未通过校验，原配置保留') end
    end
    atomic(DIR..'/last-good.json',old)
    atomic(CONF,json.stringify(c))
    -- Preserve persisted selector state across routine profile updates instead
    -- of deleting its database. Explicitly enforce the new selection below.
    local desired='privacy-auto'
    for _,o in ipairs(c.outbounds)do if o.tag=='privacy-select' then desired=o.default or desired end end
    call('/etc/init.d/iot-proxy restart >/tmp/privacy-proxy/restart.log 2>&1')
    for _=1,12 do
        local data=api('/proxies')
        if data and data.proxies and data.proxies['privacy-select'] then
            -- Disk cache may contain the previous selector; explicitly commit
            -- the new shared choice before reporting successful application.
            api('/proxies/privacy-select','PUT',{name=desired})
            local current=api('/proxies/privacy-select')
            if not current or current.now~=desired then break end
            fs.chmod('/tmp/privacy-proxy/cache.db','600')
            if not squid or call('squid -k reconfigure -f /etc/squid/squid.conf >/tmp/privacy-proxy/squid-reload.log 2>&1') then return end
            break
        end
        call('sleep 1')
    end
    atomic(CONF,old);atomic(SQUID,old_squid);fs.unlink('/tmp/privacy-proxy/cache.db');call('/etc/init.d/iot-proxy restart >/dev/null 2>&1');call('squid -k reconfigure >/dev/null 2>&1')
    error('新代理未能启动，已恢复原内核配置')
end
local function access_state()
    local v=json.parse(output('/usr/sbin/privacy-access-status'))
    assert(v and v.devices,'无法读取已授权设备')
    return v
end
local function devices()return access_state().devices end
local function temporary()
    local out={};for mac,expires in (fs.readfile(TEMP) or ''):gmatch('([%x:]+)%s+(%d+)') do
        if tonumber(expires)==0 or tonumber(expires)>os.time() then out[mac]=tonumber(expires) end
    end;return out
end
local function write_temp(t)
    local lines={};for mac,expires in pairs(t) do table.insert(lines,mac..' '..expires) end
    table.sort(lines);atomic(TEMP,table.concat(lines,'\n')..'\n')
end
local function status()
    local c,s=conf(),state();local live=api('/proxies');local p=live and live.proxies or {}
    local nodes={};local insecure=0;local available=0;local known={['privacy-auto']=true,['privacy-select']=true}
    for _,n in ipairs(peers(c)) do
        local h=(p[n.tag] or {}).history or {};local last=h[#h]
        known[n.tag]=true
        table.insert(nodes,{tag=n.tag,type=n.type,server=n.server,port=n.server_port,delay=last and last.delay or nil,insecure=n.tls and n.tls.insecure or false})
        if n.tls and n.tls.insecure then insecure=insecure+1 end
        if last and tonumber(last.delay) and tonumber(last.delay)>0 then available=available+1 end
    end
    local current=p['privacy-select'] or {};local auto=p['privacy-auto'] or {};local iot=p['privacy-iot-auto'] or {}
    local t=temporary();local access=access_state();local list=access.devices
    for _,d in ipairs(list) do
        local profile=(s.profiles or {})[d.mac] or {}
        d.proxy_active=d.enabled and d.group=='normal' and t[d.mac]~=nil
        d.proxy_permanent=d.proxy_active and t[d.mac]==0 or false
        d.proxy_remaining=d.proxy_active and not d.proxy_permanent and math.max(0,t[d.mac]-os.time()) or 0
        d.proxy_mode=profile.mode or 'global';d.proxy_node=current.now or s.selected or 'privacy-auto'
        d.proxy_node_missing=not known[d.proxy_node]
        if d.proxy_node_missing then d.proxy_node='privacy-auto' end
    end
    table.sort(nodes,function(a,b)local x=tonumber(a.delay);local y=tonumber(b.delay);x=x and x>0 and x or math.huge;y=y and y>0 and y or math.huge;return x==y and a.tag<b.tag or x<y end)
    return {ok=true,iot_mode=passthrough() and 'direct-relay' or 'hk-proxy',tls_mode=passthrough() and 'passthrough' or 'mitm',ca_required=not passthrough(),running=live~=nil,owners=access.owners or {},shared_node=true,dns_mode='protected-resolve',selected=current.now or s.selected or 'privacy-auto',auto_node=auto.now,iot_node=iot.now,iot_nodes=iot.all or {},nodes=nodes,devices=list,
        subscription_configured=type(s.url)=='string' and #s.url>0,subscription_host=((s.url or ''):match('^https://([^/?#]+)') or ''):gsub('^.-@',''),
        source=s.source or 'subscription',filter=s.filter or '',updated_at=s.updated_at or 0,skipped=s.skipped or 0,insecure_nodes=insecure,available_nodes=available,
        rule_count=#(s.rules or {}),rule_skipped=s.rule_skipped or 0,rule_url_configured=s.rule_url and s.rule_url~='' or false,
        cn_ready=fs.access(DIR..'/geosite-cn.srs') and fs.access(DIR..'/geoip-cn.srs') or false,cn_updated_at=s.cn_updated_at or 0}
end
local function download(url)
    assert(type(url)=='string' and #url<=4096 and url:match('^https://[^%s/]+') and not url:find('%c'),'订阅地址必须为 HTTPS 链接')
    local safe=url:gsub('\\','\\\\'):gsub('"','\\"')
    atomic('/tmp/privacy-proxy/subscription.curl','url = "'..safe..'"\n')
    local ok=call('curl --noproxy '..quote('*')..' --proto =https --proto-redir =https --fail --silent --show-error --location --max-redirs 4 --connect-timeout 8 --max-time 25 --max-filesize 2097152 --config /tmp/privacy-proxy/subscription.curl -o /tmp/privacy-proxy/subscription.data 2>/tmp/privacy-proxy/download.log')
    if not ok then
        -- Bootstrap through the already-running authenticated loopback parent
        -- when a data host is not reachable directly. HTTPS validation stays on.
        atomic('/tmp/privacy-proxy/subscription.curl','url = "'..safe..'"\nproxy = "http://127.0.0.1:7896"\nproxy-user = "default:'..secret()..'"\n')
        ok=call('curl --noproxy '..quote('')..' --proto =https --proto-redir =https --fail --silent --show-error --location --max-redirs 4 --connect-timeout 6 --max-time 20 --max-filesize 2097152 --config /tmp/privacy-proxy/subscription.curl -o /tmp/privacy-proxy/subscription.data 2>/tmp/privacy-proxy/download.log')
    end
    fs.unlink('/tmp/privacy-proxy/subscription.curl')
    assert(ok,'订阅下载失败（连接、HTTPS 校验或文件大小限制），现有节点未修改')
    return assert(fs.readfile('/tmp/privacy-proxy/subscription.data'),'无法读取订阅内容')
end
-- Uploads stay in the root-only manager directory. Never accept a client path,
-- extension, YAML listener or provider URL as authority to read/execute/fetch.
local function upload_path(path)
    assert(type(path)=='string' and path:match('^/tmp/privacy%-proxy/upload%.[%w]+$') and #path==42,'上传文件标识无效')
    return path
end
local function uploaded(path)
    upload_path(path)
    local st=fs.lstat(path)
    assert(st and st.type=='reg' and st.uid==0,'上传文件无效或已过期')
    fs.chmod(path,'600')
    assert(st.size>0 and st.size<=2097152,'配置文件须为 1 字节至 2MB')
    return assert(fs.readfile(path),'无法读取上传文件')
end
local function digest(path)
    return assert(output('sha256sum '..quote(path)):match('^(%x+)'),'无法校验上传文件')
end
local function local_candidate(path,filter,with_rules)
    assert(type(filter)=='string' and #filter<=120 and not filter:find('%c'),'名称筛选条件无效')
    assert(with_rules=='0' or with_rules=='1','规则选项无效')
    local data=uploaded(path)
    local ok,nodes,skipped=pcall(parser.parse,data,filter)
    assert(ok,'配置文件未能解析出兼容节点，请检查格式和筛选条件；现有配置未修改')
    local s=state();local rules,rule_skipped=s.rules or {},s.rule_skipped or 0
    if with_rules=='1' then
        local valid,r,k=pcall(rule_parser.parse,data) -- No fetch callback: offline means offline.
        assert(valid,'文件内嵌规则无效或超出限制；现有配置未修改')
        rules,rule_skipped=r,k
    end
    local valid,c,selected,squid=pcall(policy.generate,nodes,s.selected or 'privacy-auto',s.profiles or {},rules,secret(),fs.access(DIR..'/geosite-cn.srs') and fs.access(DIR..'/geoip-cn.srs'),passthrough())
    assert(valid,'配置无法应用：请检查节点、规则及路由器限制；现有配置未修改')
    atomic('/tmp/privacy-proxy/upload-check.json',json.stringify(c))
    assert(call('sing-box check -c /tmp/privacy-proxy/upload-check.json >/tmp/privacy-proxy/upload-check.log 2>&1'),'节点未通过内核校验；现有配置未修改')
    local hk,insecure=0,0
    for _,n in ipairs(nodes)do
        local name=n.tag:lower()
        if name:find('香港',1,true) or name:find('hong%s*kong') or name:find('%f[%a]hk%f[%A]') then hk=hk+1 end
        if n.tls and n.tls.insecure then insecure=insecure+1 end
    end
    return {ok=true,count=#nodes,skipped=skipped,hk=hk,insecure=insecure,rules=#rules,rule_skipped=rule_skipped,sha256=digest(path)},s,c,selected,squid,rules,rule_skipped
end
local function main()
    local action=arg[1] or 'status'
    if action=='people-add' or action=='people-rename' or action=='people-remove' or action=='people-move' then
        assert(#arg<=130,'参数数量无效')
        local cmd='/usr/sbin/privacy-access'
        for _,value in ipairs(arg)do cmd=cmd..' '..quote(value)end
        local result=json.parse(output(cmd..' 2>/tmp/privacy-proxy/people-error'))
        assert(result and result.ok,fs.readfile('/tmp/privacy-proxy/people-error') or '分组操作失败')
        return result
    elseif action=='init' then
        fs.mkdirr(DIR);fs.chmod(DIR,'700')
        local s=state()
        if not s.url then s.url=(fs.readfile('/root/iot-proxy-update.sh') or ''):match('SUB_URL="([^"\r\n]+)"');s.filter='香港|Hong Kong|HK' end
        if not fs.access(TEMP) then atomic(TEMP,fs.readfile('/tmp/privacy-proxy/devices') or '') end
        local old=fs.readfile(STATE);shared.reconcile(s,peers(conf()),temporary());save(s)
        local ok,err=pcall(function()local c,selected,squid=generated(peers(conf()),s.selected);install(c,squid);shared.set(s,selected);save(s)end)
        if not ok then atomic(STATE,old);error(err) end
        return {ok=true,selected=s.selected}
    elseif action=='status' then return status()
    elseif action=='prepare-upload' then
        assert(#arg==1,'参数数量无效')
        for path in fs.glob('/tmp/privacy-proxy/upload.*') do
            local st=fs.lstat(path)
            if st and st.type=='reg' and st.mtime<os.time()-3600 then fs.unlink(path) end
        end
        local path=output('mktemp /tmp/privacy-proxy/upload.XXXXXXXXXXXXXXXX'):gsub('%s+$','')
        upload_path(path);fs.chmod(path,'600');return {ok=true,path=path}
    elseif action=='discard-upload' then
        assert(#arg==2,'参数数量无效');upload_path(arg[2]);fs.unlink(arg[2]);return {ok=true}
    elseif action=='preview-file' or action=='import-file' then
        assert(#arg==(action=='preview-file' and 4 or 5),'参数数量无效')
        local path=upload_path(arg[2])
        local ok,result=pcall(function()
            local report,s,c,selected,squid,rules,rule_skipped=local_candidate(path,arg[3],arg[4])
            if action=='preview-file' then return report end
            assert(type(arg[5])=='string' and #arg[5]==64 and report.sha256==arg[5],'文件已变化，请重新上传预览')
            local old_state,old_conf,old_squid=fs.readfile(STATE),fs.readfile(CONF),fs.readfile(SQUID)
            local installed=false
            local applied,err=pcall(function()
                install(c,squid);installed=true
                shared.set(s,selected);s.rules=rules;s.rule_skipped=rule_skipped
                s.source='file';s.filter=arg[3];s.updated_at=os.time();s.skipped=report.skipped
                save(s)
            end)
            if not applied then
                atomic(STATE,old_state)
                if installed then install(assert(json.parse(old_conf)),old_squid);atomic(CONF,old_conf) end
                error(err)
            end
            return report
        end)
        fs.unlink('/tmp/privacy-proxy/upload-check.json')
        if action=='import-file' or not ok then fs.unlink(path) end
        assert(ok,result);return result
    elseif action=='save-subscription' then
        assert(#arg==3,'参数数量无效')
        local s=state();local url=arg[2];local filter=arg[3]
        assert(#filter<=120 and not filter:find('%c'),'名称筛选条件无效')
        if url~='' then assert(#url<=4096 and url:match('^https://[^%s/]+') and not url:find('%c'),'仅支持 HTTPS 订阅链接');s.url=url end
        assert(s.url and s.url~='','请先填写订阅链接')
        s.filter=filter;save(s);return {ok=true}
    elseif action=='update' or action=='update-remote' or action=='preview' then
        assert(#arg==1,'参数数量无效')
        local s=state()
        if action=='update' and s.source=='file' then return {ok=true,skipped_source=true} end
        local data=download(s.url);local ok,nodes,skipped=pcall(parser.parse,data,s.filter or '')
        fs.unlink('/tmp/privacy-proxy/subscription.data')
        assert(ok,nodes)
        if action=='preview' then return {ok=true,count=#nodes,skipped=skipped} end
        local rules,rule_skipped=rule_parser.parse(data,function(url)local raw=download(url);fs.unlink('/tmp/privacy-proxy/subscription.data');return raw end)
        local old=fs.readfile(STATE)
        if not s.rule_url or s.rule_url=='' then s.rules=rules;s.rule_skipped=rule_skipped;save(s) end
        local selected
        local applied,err=pcall(function()local c,squid;c,selected,squid=generated(nodes,s.selected or 'privacy-auto');install(c,squid)end)
        if not applied then atomic(STATE,old);error(err) end
        shared.set(s,selected);s.source='subscription';s.updated_at=os.time();s.skipped=skipped;save(s)
        return {ok=true,count=#nodes,skipped=skipped}
    elseif action=='save-rules' then
        assert(#arg==2,'参数数量无效');local s=state();local url=arg[2]
        assert(url=='' or (#url<=4096 and url:match('^https://[^%s/]+') and not url:find('%c')),'规则订阅必须为 HTTPS 链接')
        s.rule_url=url;save(s);return {ok=true}
    elseif action=='update-rules' then
        assert(#arg==1,'参数数量无效')
        local s=state();local old=fs.readfile(STATE)
        local data=download(s.rule_url and s.rule_url~='' and s.rule_url or s.url);fs.unlink('/tmp/privacy-proxy/subscription.data')
        s.rules,s.rule_skipped=rule_parser.parse(data,function(url)local raw=download(url);fs.unlink('/tmp/privacy-proxy/subscription.data');return raw end)
        if s.rule_url and s.rule_url~='' then assert(#s.rules>0,'该链接没有兼容规则，现有规则保留') end
        local c,selected,squid
        -- The two fixed upstreams are data-only binary rule sets. Validate using
        -- the actual core before replacing the previous on-disk snapshot.
        local previous={}
        local ok,err=pcall(function()
            for _,entry in ipairs({{'geosite-cn','sing-geosite'},{'geoip-cn','sing-geoip'}}) do
                local path=DIR..'/'..entry[1]..'.srs';previous[path]=fs.readfile(path) or false
                local data=download('https://raw.githubusercontent.com/SagerNet/'..entry[2]..'/rule-set/'..entry[1]..'.srs')
                fs.unlink('/tmp/privacy-proxy/subscription.data');atomic(path,data)
            end
            s.cn_updated_at=os.time();save(s)
            c,selected,squid=generated(peers(conf()),s.selected or 'privacy-auto');install(c,squid)
        end)
        if not ok then for path,data in pairs(previous) do if data then atomic(path,data) else fs.unlink(path) end end;atomic(STATE,old);error(err) end
        return {ok=true,count=#(s.rules or {}),skipped=s.rule_skipped or 0}
    elseif action=='test-all' then
        assert(#arg==1,'参数数量无效')
        -- The core URL-test group probes with its bounded concurrency; do not
        -- launch hundreds of curl processes on this small router.
        local data=api('/group/privacy-auto/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=6000')
        assert(data,'批量测速请求失败，请稍后刷新');return {ok=true}
    elseif action=='select' then
        assert(#arg==2,'参数数量无效')
        local c=conf();local target=arg[2];local found=target=='privacy-auto'
        for _,n in ipairs(peers(c)) do if n.tag==target then found=true end end
        assert(found,'节点不存在，请刷新列表')
        local old_conf,old_state=fs.readfile(CONF),fs.readfile(STATE)
        local before=api('/proxies/privacy-select');assert(before and before.now,'无法读取当前出口')
        local ok,err=pcall(function()
            api('/proxies/privacy-select','PUT',{name=target})
            local live=api('/proxies/privacy-select');assert(live and live.now==target,'切换失败，未确认内核选择')
            for _,n in ipairs(c.outbounds) do if n.tag=='privacy-select' then n.default=target end end
            atomic(CONF,json.stringify(c));local s=state();shared.set(s,target);s.node_changed_at=os.time();save(s)
        end)
        if not ok then atomic(CONF,old_conf);atomic(STATE,old_state);api('/proxies/privacy-select','PUT',{name=before.now});error(err) end
        return {ok=true,selected=target}
    elseif action=='test' then
        assert(#arg==2,'参数数量无效')
        local found=arg[2]=='privacy-auto';for _,n in ipairs(peers(conf())) do if n.tag==arg[2] then found=true end end
        assert(found,'节点不存在')
        local data=api('/proxies/'..esc(arg[2])..'/delay?timeout=6000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204')
        assert(data and data.delay,'测速失败或超过 6 秒；未改变节点选择')
        return {ok=true,delay=data.delay}
    elseif action=='temporary' or action=='cancel' then
        assert((action=='temporary' and (#arg==3 or #arg==5)) or (action=='cancel' and #arg==2),'参数数量无效')
        local mac=arg[2]:lower():gsub('-',':');assert(mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$'),'MAC 地址无效')
        local t=temporary();local s=state();s.profiles=s.profiles or {}
        local previous=s.profiles[mac];local fast=false
        if action=='temporary' then
            local found=false;for _,d in ipairs(devices()) do if d.mac==mac and d.enabled and d.group=='normal' then found=true end end
            assert(found,'只能临时切换已启用的普通设备；IoT 使用直连转发，未授权设备不可绕过白名单')
            local minutes=tonumber(arg[3]);assert(minutes and minutes%1==0 and minutes>=0 and minutes<=1440,'时长必须为 0（长期）或 1–1440 分钟')
            local mode=arg[4] or 'global';local node=arg[5] or 'privacy-select'
            assert(mode=='rule' or mode=='global','请选择规则或全局模式')
            local found=node=='privacy-auto' or node=='privacy-select';for _,n in ipairs(peers(conf())) do if n.tag==node then found=true end end
            assert(found,'节点不存在，请刷新后重选')
            if mode=='rule' then assert(fs.access(DIR..'/geosite-cn.srs') and fs.access(DIR..'/geoip-cn.srs'),'请先更新国内分流规则') end
            local live=api('/proxies');assert(live and live.proxies,'代理未运行，未修改设备分流')
            fast=s.shared_node_version==1 and previous and previous.mode==mode
            t[mac]=minutes==0 and 0 or os.time()+minutes*60
            s.profiles[mac]={mode=mode,node=node}
            if node=='privacy-select' then node=s.selected or 'privacy-auto' end
            shared.set(s,node);s.node_changed_at=os.time()
        else t[mac]=nil;s.profiles[mac]=nil end
        local before=fs.readfile(TEMP) or '';local old_state=fs.readfile(STATE);local old_conf=fs.readfile(CONF);local old_squid=fs.readfile(SQUID)
        save(s)
        local ok,err=pcall(function()
            if fast then
                -- Node/duration-only edits do not need to restart IoT or rebuild
                -- identical mode rules. Selector interrupts old manual streams.
                api('/proxies/privacy-select','PUT',{name=s.selected})
                local live=api('/proxies/privacy-select');assert(live and live.now==s.selected,'共用节点切换失败')
                local c=conf();for _,o in ipairs(c.outbounds)do if o.tag=='privacy-select' then o.default=s.selected end end
                atomic(CONF,json.stringify(c))
            else
                local c,_,squid=generated(peers(conf()),s.selected or 'privacy-auto');install(c,squid)
            end
            write_temp(t)
            assert(call('/etc/privacy-classify.sh >/tmp/privacy-proxy/classify.log 2>&1'),'分流应用失败')
        end)
        if not ok then atomic(STATE,old_state);atomic(TEMP,before);atomic(CONF,old_conf);atomic(SQUID,old_squid);call('/etc/init.d/iot-proxy restart >/dev/null 2>&1');call('squid -k reconfigure >/dev/null 2>&1');call('/etc/privacy-classify.sh >/dev/null 2>&1');error(err) end
        return {ok=true}
    else error('不支持的管理操作') end
end
local ok,result=pcall(main)
if ok then print(json.stringify(result)) else
    io.stderr:write(tostring(result):gsub('^.-:%d+: ',''),'\n');os.exit(1)
end
