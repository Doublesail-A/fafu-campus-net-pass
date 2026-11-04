local fs=require('nixio.fs');local j=require('luci.jsonc')
local dir='/etc/privacy-proxy';fs.mkdirr(dir);fs.chmod(dir,'700')
local function write(path,data)assert(fs.writefile(path,data));fs.chmod(path,'600')end
local secret=fs.readfile(dir..'/api.secret')
if not secret then secret=assert(io.popen('openssl rand -hex 24')):read('*a');write(dir..'/api.secret',secret)end
secret=secret:gsub('%s','');assert(secret:match('^%x+$'))
if not fs.access(dir..'/settings.json') then write(dir..'/settings.json',j.stringify({source='file',url='',filter='',selected='privacy-auto',profiles={},rules={}}))end
if not fs.access(dir..'/devices')then write(dir..'/devices','')end
if not fs.access('/etc/sing-box/privacy-iot.json') then
 fs.mkdirr('/etc/sing-box');fs.mkdirr('/tmp/privacy-proxy');fs.chmod('/tmp/privacy-proxy','700')
 local c={log={level='warn'},dns={servers={{type='udp',tag='dns-direct',server='223.5.5.5'}},final='dns-direct',strategy='ipv4_only'},
 inbounds={{type='redirect',tag='redirect-in',listen='0.0.0.0',listen_port=7894},{type='http',tag='squid-parent',listen='127.0.0.1',listen_port=7896,users={{username='default',password=secret}}},{type='redirect',tag='iot-in',listen='0.0.0.0',listen_port=7895},{type='redirect',tag='direct-in',listen='0.0.0.0',listen_port=7897}},
 outbounds={{type='direct',tag='direct'}},route={default_domain_resolver='dns-direct',rules={{inbound={'squid-parent','redirect-in'},action='reject'}},final='direct'},
 experimental={clash_api={external_controller='127.0.0.1:9091',secret=secret}}}
 write('/etc/sing-box/privacy-iot.json',j.stringify(c))
end
