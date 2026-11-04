-- Execute the real manager with isolated file storage and mocked daemon/API
-- control. Native sing-box validation is real; no subscription fetch is allowed.
local stage,dir=arg[1],arg[2]
local realfs=require('nixio.fs');local realsys=require('luci.sys');local json=require('luci.jsonc')
local native_dofile=dofile
local roots={['/etc/privacy-proxy']=dir..'/settings',['/etc/sing-box']=dir..'/core',['/etc/squid']=dir..'/squid',['/tmp/privacy-proxy']=dir..'/runtime'}
local function map(path)
    for from,to in pairs(roots)do if path==from or path:sub(1,#from+1)==from..'/' then return to..path:sub(#from+1) end end
    return path
end
local function command(cmd)
    for from,to in pairs(roots)do cmd=cmd:gsub(from:gsub('%-','%%-'),to) end
    return cmd
end
local mockfs=setmetatable({},{__index=realfs})
for _,name in ipairs({'readfile','writefile','access','chmod','lstat','unlink','mkdirr'})do mockfs[name]=function(path,...)return realfs[name](map(path),...)end end
mockfs.rename=function(a,b)return realfs.rename(map(a),map(b))end
mockfs.glob=function(path)return realfs.glob(map(path))end
local fail_save=false
mockfs.writefile=function(path,data)
    if fail_save and path=='/etc/privacy-proxy/settings.json.new' then fail_save=false;return nil end
    return realfs.writefile(map(path),data)
end
local selected='香港 fixture';local restarts=0;local fail_start=false
local mocksys={
    call=function(cmd)
        if cmd:find('sing-box check',1,true)then return realsys.call(command(cmd))end
        if cmd:find('/etc/init.d/iot-proxy restart',1,true)then restarts=restarts+1;return 0 end
        if cmd:find('squid -k',1,true) or cmd:find('sleep 1',1,true)then return 0 end
        error('Unexpected system mutation: '..cmd:match('^[^ ]+'))
    end,
    exec=function(cmd)
        if cmd:find('sha256sum ',1,true)then return realsys.exec(command(cmd))end
        if cmd:find('mktemp ',1,true)then return '/tmp/privacy-proxy/'..assert(realsys.exec(command(cmd)):match('/([^/]+)%s*$'))..'\n' end
        if cmd:find('curl ',1,true) and cmd:find('http://127.0.0.1:9091/',1,true)then
            if fail_start then return '' end
            if cmd:find(' -X ',1,true)then selected=json.parse(mockfs.readfile('/tmp/privacy-proxy/api.body')).name;return '{}' end
            if cmd:find('/proxies/privacy-select',1,true)then return json.stringify({now=selected})end
            return json.stringify({proxies={['privacy-select']={now=selected}}})
        end
        error('Unexpected fetch/command (offline import must not download)')
    end
}
package.loaded['nixio.fs']=mockfs;package.loaded['luci.sys']=mocksys
dofile=function(path)return native_dofile(path:gsub('^/usr/share/privacy%-access/',stage..'/rootfiles/usr/share/privacy-access/'))end
for _,path in pairs(roots)do assert(realfs.mkdirr(path))end
local function write(path,data)assert(mockfs.writefile(path,data))end
local state_path='/etc/privacy-proxy/settings.json'
local initial={source='subscription',url='https://example.invalid/private-token',selected=selected,profiles={['02:00:00:00:00:88']={mode='global',node=selected}},rules={{domain={'keep.example'},target='direct'}}}
write(state_path,json.stringify(initial));write('/etc/privacy-proxy/api.secret','test-only-api-key')
local policy=dofile('/usr/share/privacy-access/proxy-policy.lua')
local nodes={{type='anytls',tag=selected,server='example.com',server_port=443,password='dummy',tls={enabled=true}}}
local c,_,squid=policy.generate(nodes,selected,initial.profiles,initial.rules,'test-only-api-key',false)
write('/etc/sing-box/privacy-iot.json',json.stringify(c));write('/etc/squid/privacy-proxy.conf',squid)
write('/etc/privacy-proxy/devices','02:00:00:00:00:88 0\n')
local function run(args,expected)
    arg=args;local saved_exit,saved_print,saved_err=os.exit,print,io.stderr;local result,reason
    os.exit=function(code)error({exit=code})end
    print=function(text)result=json.parse(text)end
    io.stderr={write=function(_,text)reason=text end}
    local ok,err=pcall(native_dofile,stage..'/rootfiles/usr/share/privacy-access/proxy.lua')
    os.exit,print,io.stderr=saved_exit,saved_print,saved_err
    assert(ok==expected,'Manager result differs for '..args[1]..': '..tostring(reason or err));return result
end
local function fresh(data)
    local upload=run({'prepare-upload'},true).path;write(upload,data);return upload
end
local sample='mixed-port: 8999\nexternal-controller: 0.0.0.0:9090\ndns: {enable: true}\nproxies:\n - {name: "香港 new", type: anytls, server: example.org, port: 443, password: dummy}\nrules:\n - DOMAIN-SUFFIX,example.cn,DIRECT\n - RULE-SET,remote,PROXY\n - MATCH,PROXY\nrule-providers:\n remote: {type: http, behavior: domain, url: "https://example.invalid/do-not-fetch"}\n'
local old=mockfs.readfile(state_path);local oldcore=mockfs.readfile('/etc/sing-box/privacy-iot.json')
local path=fresh(sample);local preview=run({'preview-file',path,'','1'},true)
assert(preview.count==1 and preview.hk==1 and preview.rules==2 and preview.rule_skipped==1 and #preview.sha256==64)
assert(mockfs.readfile(state_path)==old and mockfs.readfile('/etc/sing-box/privacy-iot.json')==oldcore and restarts==0)
run({'import-file',path,'','1',string.rep('0',64)},false)
assert(not mockfs.access(path) and mockfs.readfile(state_path)==old and restarts==0)
path=fresh(sample);preview=run({'preview-file',path,'','1'},true)
run({'import-file',path,'','1',preview.sha256},true)
local s=json.parse(mockfs.readfile(state_path));assert(s.source=='file' and s.url==initial.url and #s.rules==2 and s.selected=='privacy-auto')
assert(not mockfs.access(path) and restarts==1)
assert(s.profiles['02:00:00:00:00:88'].mode=='global' and s.profiles['02:00:00:00:00:88'].node==s.selected)
assert(mockfs.readfile('/etc/privacy-proxy/devices')=='02:00:00:00:00:88 0\n')
assert(run({'update'},true).skipped_source==true)
local applied=mockfs.readfile(state_path);local appliedcore=mockfs.readfile('/etc/sing-box/privacy-iot.json')
for _,bad in ipairs({'not yaml or nodes','proxies: []',(sample:gsub('香港 new','Japan new'))})do
    path=fresh(bad);run({'preview-file',path,'','1'},false)
    assert(not mockfs.access(path) and mockfs.readfile(state_path)==applied and mockfs.readfile('/etc/sing-box/privacy-iot.json')==appliedcore)
end
path=fresh(sample);run({'preview-file',path,'no matching node','0'},false)
path=fresh(string.rep('x',2097153));run({'preview-file',path,'','0'},false)
run({'preview-file','/etc/shadow','','0'},false)
path=fresh('');mockfs.unlink(path);assert(realfs.symlink('/etc/shadow',map(path)))
run({'preview-file',path,'','0'},false);assert(not mockfs.access(path))
path=fresh(sample);preview=run({'preview-file',path,'','0'},true);assert(preview.rules==2)
fail_start=true;run({'import-file',path,'','0',preview.sha256},false);fail_start=false
assert(mockfs.readfile(state_path)==applied and mockfs.readfile('/etc/sing-box/privacy-iot.json')==appliedcore)
path=fresh((sample:gsub('香港 new','香港 changed')));preview=run({'preview-file',path,'','0'},true)
fail_save=true;run({'import-file',path,'','0',preview.sha256},false)
assert(mockfs.readfile(state_path)==applied and mockfs.readfile('/etc/sing-box/privacy-iot.json')==appliedcore)
print('PASS offline upload: preview immutable, real core validation, embedded rules only/no fetch, hash binding, import, subscription pause, rollback, invalid/oversize/no-HK/symlink/path rejection.')
