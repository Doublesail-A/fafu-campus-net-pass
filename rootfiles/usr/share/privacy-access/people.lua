-- Metadata-only transactions. Never change enabled/group/MAC or run a classifier.
local fs=require('nixio.fs')
local json=require('luci.jsonc')
local c=require('uci').cursor(arg[1])
local path=arg[1]..'/privacy_access'
local function name(s,empty)
    assert(type(s)=='string','分组名称无效')
    s=s:match('^%s*(.-)%s*$')
    assert(#s<=80 and not s:find('%c') and (empty or s~='') and s~='未分组','分组名称须为 1–80 字节，不能含控制字符或使用“未分组”')
    return s
end
local can_revert=false
local ok,result=pcall(function()
    assert(c:load('privacy_access'),'无法读取设备配置')
    assert(next(c:changes('privacy_access') or {})==nil,'存在未提交的白名单修改，请先保存或撤销后再整理分组')
    can_revert=true
    local all,known,explicit={}, {},c:get('privacy_access','main','owners') or {}
    if type(explicit)=='string' then explicit={explicit} end
    for _,v in ipairs(explicit)do if v~='' then known[v]=true end end
    c:foreach('privacy_access','device',function(d)
        all[#all+1]=d
        if d.owner and d.owner~='' then known[d.owner]=true end
    end)
    local action=arg[2]
    local target=name(arg[3],action=='people-move')
    local count=0
    if action=='people-add' then
        assert(#arg==3,'参数数量无效');assert(not known[target],'分组已存在');known[target]=true
    elseif action=='people-rename' or action=='people-remove' then
        assert(#arg==(action=='people-rename' and 4 or 3),'参数数量无效')
        assert(known[target],'分组不存在，请刷新')
        local dest=action=='people-rename' and name(arg[4]) or ''
        assert(not known[dest],'目标分组已存在，请使用移动设备合并')
        known[target]=nil;if dest~='' then known[dest]=true end
        for _,d in ipairs(all)do if d.owner==target then assert(c:set('privacy_access',d['.name'],'owner',dest));count=count+1 end end
    elseif action=='people-move' then
        assert(#arg>=4 and #arg<=131,'请选择 1–128 台设备')
        assert(target=='' or known[target],'目标分组不存在，请先新建')
        local wanted={}
        for i=4,#arg do
            local mac=arg[i]:lower():gsub('-',':')
            assert(mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$'),'MAC 地址无效');wanted[mac]=true
        end
        -- Validate every requested identity before staging any changes.
        local found={}
        for _,d in ipairs(all)do local mac=(d.mac or ''):lower():gsub('-',':');if wanted[mac]then found[mac]=true end end
        for mac in pairs(wanted)do assert(found[mac],'包含未授权或已删除的设备，未移动任何设备')end
        for _,d in ipairs(all)do
            if wanted[(d.mac or ''):lower():gsub('-',':')]then assert(c:set('privacy_access',d['.name'],'owner',target));count=count+1 end
        end
    else error('未知分组操作')end
    local owners={};for v in pairs(known)do owners[#owners+1]=v end;table.sort(owners)
    assert(#owners<=128,'最多保存 128 个人员分组')
    c:delete('privacy_access','main','owners')
    if #owners>0 then assert(c:set('privacy_access','main','owners',owners))end
    local previous=assert(fs.readfile(path),'无法备份设备配置')
    local committed,err=pcall(function()assert(c:save('privacy_access') and c:commit('privacy_access'),'无法保存分组')end)
    if not committed then
        c:revert('privacy_access')
        assert(fs.writefile(path..'.people-restore',previous));fs.chmod(path..'.people-restore','600');assert(fs.rename(path..'.people-restore',path))
        error(err)
    end
    fs.chmod(path,'600')
    return {ok=true,count=count}
end)
if ok then print(json.stringify(result))else if can_revert then c:revert('privacy_access')end;io.stderr:write(tostring(result):gsub('^.-:%d+: ',''),'\n');os.exit(1)end
