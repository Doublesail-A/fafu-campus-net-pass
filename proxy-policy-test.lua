local base=arg[1]..'/rootfiles/usr/share/privacy-access/'
local p=dofile(base..'proxy-policy.lua')
local rules=dofile(base..'proxy-rules.lua')
local json=require('luci.jsonc')
local shared=dofile(base..'proxy-shared.lua')
local r,skip=rules.parse('rules:\n - DOMAIN-SUFFIX,example.cn,DIRECT\n - DOMAIN,blocked.example,REJECT\n - GEOIP,CN,DIRECT\n - PROCESS-NAME,bad.exe,DIRECT\n - MATCH,PROXY\n')
assert(#r==4 and skip==1 and r[1].domain_suffix[1]=='example.cn' and r[2].target=='reject')
local bad,n=rules.parse('{"rules":[{"process_name":["foo"],"outbound":"direct"},{"domain":["safe.example"],"outbound":"direct"}],"inbounds":[{}]}')
assert(#bad==1 and n==1 and bad[1].target=='direct')
assert(#rules.parse('anytls://secret@example.com:443#test')==0)
local provider,pskip=rules.parse('rules:\n - RULE-SET,cn,DIRECT\n - MATCH,PROXY\nrule-providers:\n cn:\n  type: http\n  behavior: domain\n  url: https://example.com/cn.yaml\n',function(url)assert(url=='https://example.com/cn.yaml');return 'payload:\n - +.provider.example\n - exact.example\n' end)
assert(#provider==2 and pskip==0 and provider[1].domain_suffix[1]=='provider.example' and provider[1].domain[1]=='exact.example')
local nodes={{type='anytls',tag='Japan',server='example.com',server_port=443,password='dummy',tls={enabled=true}},
    {type='anytls',tag='香港01',server='hk.example.com',server_port=443,password='dummy',tls={enabled=true}}}
local mac='10:00:00:00:00:01'
local c,selected,squid=p.generate(nodes,'privacy-auto',{[mac]={mode='rule',node='Japan'}},r,'dummysecret',true)
local transparent,_,transparent_squid=p.generate(nodes,'privacy-auto',{[mac]={mode='rule',node='Japan'}},r,'dummysecret',true,true)
assert(transparent_squid:find('generate-host-certificates=off',1,true))
local function same(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not same(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
assert(transparent.route.rules[2].outbound=='direct')
for _,o in ipairs(transparent.outbounds)do assert(o.tag~='privacy-iot-auto') end
local nohk=p.generate({nodes[1]},'Japan',{}, {},'dummy',true,true)
assert(nohk.route.rules[2].outbound=='direct')
assert(same(c.inbounds,transparent.inbounds),'Listener and identity graph preserved')
assert(selected=='privacy-auto' and #c.inbounds[2].users==2)
assert(c.inbounds[2].listen=='127.0.0.1' and squid:find('arp '..mac,1,true) and squid:find('login=device_100000000001:',1,true))
assert(c.route.rules[2].inbound[1]=='iot-in' and c.route.rules[2].outbound=='privacy-iot-auto')
assert(c.route.rules[3].rules[2].rule_set[1]=='geosite-cn')
assert(c.route.rules[4].action=='resolve' and c.route.rules[4].server=='dns-proxy')
local iot;for _,o in ipairs(c.outbounds) do if o.tag=='privacy-iot-auto' then iot=o end end
assert(#iot.outbounds==1 and iot.outbounds[1]=='香港01')
assert(c.route.rules[#c.route.rules].outbound=='privacy-select')
for _,r in ipairs(c.route.rules) do if r.action=='reject' then assert(r.outbound==nil) end end
assert(c.route.rules[#c.route.rules].rules[1].rules[2].source_mac_address[1]==mac)
assert(not pcall(p.generate,nodes,'privacy-auto',{[mac]={mode='rule',node='Japan'}},{},'dummy',false))
local g=p.generate(nodes,'privacy-auto',{[mac]={mode='global',node='Japan'}},{},'dummy',true)
assert(#g.route.rules==3 and g.route.rules[3].outbound=='privacy-select')
local profiles={}
for i=1,128 do profiles[string.format('10:00:00:00:00:%02x',i)]={mode='rule',node=i%2==0 and 'Japan' or '香港01'} end
local many=p.generate(nodes,'Japan',profiles,r,'dummy',true)
assert(#many.route.rules==#c.route.rules,'Rules must not multiply per device')
assert(#many.route.rules[3].rules[1].rules[2].source_mac_address==128)
local excessive={};for i=1,1000 do excessive[i]={domain={'host'..i..'.example'},target='direct'} end
assert(not pcall(p.generate,nodes,'Japan',profiles,excessive,'dummy',true),'Embedded identity expansion must remain memory-bounded')
for _,rule in ipairs(many.route.rules)do assert(not rule.outbound or rule.outbound=='direct' or rule.outbound=='privacy-select' or rule.outbound=='privacy-iot-auto') end
for _,o in ipairs(many.outbounds)do if o.type=='urltest' or o.type=='selector' then assert(o.interrupt_exist_connections) end end
local s={selected='privacy-auto',profiles={a={mode='rule',node='Japan'},b={mode='global',node='香港01'}}}
shared.reconcile(s,nodes,{a=1234567890})
assert(s.selected=='Japan' and s.profiles.b.node=='Japan' and s.profiles.b.mode=='global')
shared.set(s,'香港01');assert(s.profiles.a.node=='香港01' and s.profiles.a.mode=='rule')
shared.reconcile(s,nodes,{a=1,b=2});assert(s.selected=='香港01','Old profile cannot restore its independent node')
shared.reconcile(s,{{tag='香港01'}},{a=1});assert(s.selected=='香港01')
shared.set(s,'missing');shared.reconcile(s,nodes,{a=1});assert(s.selected=='privacy-auto')
-- Validate fixtures with the installed core as well as logical assertions.
local file=assert(io.open('/tmp/privacy-proxy-policy-test.json','w'));file:write(json.stringify(c));file:close()
print('PASS policy: protected DNS, one shared node, last-write synchronization, HK-only IoT, aggregated mode rules, per-device identities, global no-direct and safe rule import.')
