local M={}
local function clone(t)local r={};for k,v in pairs(t) do r[k]=type(v)=='table' and clone(v) or v end;return r end
function M.generate(nodes,selected,profiles,rules,secret,cn_ready,passthrough)
    local count,rule_count=0,0
    for _,p in pairs(profiles or {}) do count=count+1;if p.mode=='rule' then rule_count=rule_count+1 end end
    assert(count<=128,'最多保存 128 台设备代理设置')
    local function weight(v)local n=1;if type(v)=='table' then for _,x in pairs(v) do n=n+weight(x) end end;return n end
    -- Identity arrays are embedded beside each imported condition. Include that
    -- expansion in the budget even though rules are compiled only once per mode.
    assert(weight(rules or {})+#(rules or {})*math.max(1,rule_count)*2<=64000,'额外分流规则过大，会影响路由器响应；请精简规则提供器')
    local tags,hk,known={},{}, {['privacy-auto']=true,['privacy-select']=true}
    for _,n in ipairs(nodes) do
        n=clone(n);nodes[_]=n
        n.routing_mark=201;tags[#tags+1]=n.tag;known[n.tag]=true
        local name=n.tag:lower()
        if name:find('香港',1,true) or name:find('hong%s*kong') or name:find('%f[%a]hk%f[%A]') then hk[#hk+1]=n.tag end
    end
    assert(passthrough or #hk>0,'IoT 固定香港出口：订阅必须保留至少一个香港节点，请清空或调整名称筛选')
    if selected=='privacy-select' or not known[selected] then selected='privacy-auto' end
    local choices={'privacy-auto'};for _,t in ipairs(tags) do choices[#choices+1]=t end
    local c={log={level='warn',timestamp=true},
        dns={servers={{type='https',tag='dns-proxy',server='1.1.1.1',server_port=443,path='/dns-query',detour='privacy-select'},
            {type='udp',tag='dns-direct',server='223.5.5.5',server_port=53}},final='dns-direct',strategy='ipv4_only',cache_capacity=4096,timeout='6s'},
        inbounds={{type='redirect',tag='redirect-in',listen='0.0.0.0',listen_port=7894},
            {type='http',tag='squid-parent',listen='127.0.0.1',listen_port=7896,users={{username='default',password=secret}}},
            {type='redirect',tag='iot-in',listen='0.0.0.0',listen_port=7895},
            {type='redirect',tag='direct-in',listen='0.0.0.0',listen_port=7897}},
        -- Direct destinations already passed Squid for web traffic. Preserve UA3F
        -- handling for other direct TCP; only node sockets carry bypass mark 201.
        outbounds={{type='direct',tag='direct'}},
        -- Kernel routing already selects the existing primary/fallback WAN.
        -- SO_BINDTODEVICE breaks reply delivery after the existing local UA3F
        -- OUTPUT REDIRECT. Do not bypass UA3F to work around this.
        route={default_domain_resolver='dns-direct',auto_detect_interface=false,rules={{action='sniff',sniffer={'tls','http'}},
            {inbound={'iot-in'},action='route',outbound=passthrough and 'direct' or 'privacy-iot-auto'}},final='privacy-select'},
        experimental={clash_api={external_controller='127.0.0.1:9091',secret=secret},cache_file={enabled=true,path='/tmp/privacy-proxy/cache.db'}}}
    if passthrough then table.insert(c.route.rules,{inbound={'direct-in'},action='route',outbound='direct'}) end
    if cn_ready then
        c.route.rule_set={}
        for _,t in ipairs({'geosite-cn','geoip-cn'}) do c.route.rule_set[#c.route.rule_set+1]={type='local',tag=t,format='binary',path='/etc/privacy-proxy/'..t..'.srs'} end
    end
    for _,n in ipairs(nodes) do c.outbounds[#c.outbounds+1]=n end
    c.outbounds[#c.outbounds+1]={type='urltest',tag='privacy-auto',outbounds=tags,url='https://www.gstatic.com/generate_204',interval='10m',tolerance=50,interrupt_exist_connections=true}
    if not passthrough then c.outbounds[#c.outbounds+1]={type='urltest',tag='privacy-iot-auto',outbounds=hk,url='https://www.gstatic.com/generate_204',interval='10m',tolerance=50,interrupt_exist_connections=true} end
    c.outbounds[#c.outbounds+1]={type='selector',tag='privacy-select',outbounds=choices,default=selected,interrupt_exist_connections=true}
    local squid={
        passthrough and '# Managed device proxy: TLS end-to-end TCP tunnel; HTTP UA policy retained.' or '# Managed device proxy: shared CA/bump/UA policy still applies.',
        'http_port 172.31.255.1:3132 intercept name=privacy-proxy-http',
        'https_port 172.31.255.1:3131 intercept ssl-bump cert=/etc/squid/ca.pem generate-host-certificates='..(passthrough and 'off' or 'on')..' dynamic_cert_mem_cache_size=8MB name=privacy-proxy-https',
        'acl privacy_proxy_listener myportname privacy-proxy-http privacy-proxy-https'}
    local keys={};for mac in pairs(profiles or {}) do keys[#keys+1]=mac end;table.sort(keys)
    local groups={rule={macs={},users={}},global={macs={},users={}}}
    for _,mac in ipairs(keys) do
        local p=profiles[mac];local id=mac:gsub(':','');local username='device_'..id
        assert(mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$'),'Invalid profile MAC')
        local group=assert(groups[p.mode],'Invalid profile mode')
        group.macs[#group.macs+1]=mac;group.users[#group.users+1]=username
        c.inbounds[2].users[#c.inbounds[2].users+1]={username=username,password=secret}
        squid[#squid+1]='acl privacy_device_'..id..' arp '..mac
        squid[#squid+1]='cache_peer 127.0.0.1 parent 7896 0 no-query no-digest proxy-only name=privacy_'..id..' login='..username..':'..secret
        squid[#squid+1]='cache_peer_access privacy_'..id..' allow privacy_proxy_listener privacy_device_'..id
        squid[#squid+1]='cache_peer_access privacy_'..id..' deny all'
    end
    -- All devices share one selector. Compile rules once per mode, not once per
    -- MAC: 128 devices no longer multiply a large subscription rule list.
    for _,mode in ipairs({'rule','global'}) do
      local group=groups[mode]
      if #group.macs>0 then
        local identity={type='logical',mode='or',rules={
            {inbound={'squid-parent'},auth_user=group.users},
            {inbound={'redirect-in'},source_mac_address=group.macs}}}
        local function route(match,action,outbound)
            if next(match)==nil then match={network={'tcp'}} end -- jsonc encodes {} as [], not an object
            local r={type='logical',mode='and',rules={clone(identity),match},action=action or 'route',outbound=outbound}
            c.route.rules[#c.route.rules+1]=r
        end
        if mode=='rule' then
            assert(cn_ready,'国内规则未准备好，不能启用规则模式')
            route({rule_set={'geosite-cn'}},'route','direct')
            route({},'resolve')
            -- Explicit server: do not let poisoned local UDP answers enter
            -- either GeoIP classification or the subsequent proxy dial.
            c.route.rules[#c.route.rules].server='dns-proxy'
            -- Domestic-first is intentional, even if a supplied MATCH says proxy.
            route({rule_set={'geoip-cn'}},'route','direct')
            for _,source in ipairs(rules or {}) do
                local r=clone(source);local dest=r.target;r.target=nil
                local destination
                if dest~='reject' then destination=dest=='direct' and 'direct' or 'privacy-select' end
                route(r,dest=='reject' and 'reject' or 'route',destination)
            end
        end
        c.route.rules[#c.route.rules+1]={type='logical',mode='and',rules={clone(identity)},action='route',outbound='privacy-select'}
      end
    end
    squid[#squid+1]='cache_peer 127.0.0.1 parent 7896 0 no-query no-digest proxy-only name=privacy_upstream login=default:'..secret
    for _,mac in ipairs(keys) do squid[#squid+1]='cache_peer_access privacy_upstream deny privacy_device_'..mac:gsub(':','') end
    squid[#squid+1]='cache_peer_access privacy_upstream allow privacy_proxy_listener'
    squid[#squid+1]='cache_peer_access privacy_upstream deny all'
    squid[#squid+1]='never_direct allow privacy_proxy_listener'
    return c,selected,table.concat(squid,'\n')..'\n'
end
return M
