'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require privacy-devices-20261021b as devices';

var callCommandAccess = rpc.declare({
    object: 'session', method: 'access', params: ['scope', 'object', 'function'], expect: { access: false }
});
var normalizeMac = function(value) { return (value || '').trim().toLowerCase().replace(/-/g, ':'); };

return view.extend({
    handleSaveApply: null,
    handleSave: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            fs.exec('/usr/sbin/privacy-access-status', []),
            callCommandAccess('file', '/usr/sbin/privacy-access', 'exec')
        ]).then(function(results) {
            if (results[0].code !== 0) throw new Error(results[0].stderr || '无法读取设备白名单');
            var data = JSON.parse(results[0].stdout);
            data.can_write = results[1] === true;
            return data;
        });
    },

    run: function(args) {
        return fs.exec('/usr/sbin/privacy-access', args).then(function(result) {
            if (result.code !== 0) throw new Error(result.stderr || '保存或应用失败');
            return JSON.parse(result.stdout);
        });
    },

    refresh: function() {
        return this.load().then(L.bind(function(data) {
            this.data = data;
            this.content.replaceChildren(this.buildContent(data));
        }, this));
    },

    partition: function(data) {
        var byMac = {};
        (data.devices || []).concat(data.unregistered || []).forEach(function(device) {
            var mac = normalizeMac(device.mac);
            if (!mac) return;
            var copy = Object.assign({}, device, {mac: mac});
            if (!byMac[mac] || copy.configured) byMac[mac] = copy;
        });
        var groups = [[], [], []];
        Object.keys(byMac).forEach(function(mac) {
            var d = byMac[mac];
            if (d.connected) groups[d.configured && d.enabled ? 1 : 0].push(d);
            else if (d.configured) groups[2].push(d);
        });
        groups.forEach(function(group) {
            group.sort(function(a, b) {
                return devices.compare(a,b);
            });
        });
        return groups;
    },

    registrationSettings: function() {
        return this.run(['registration-status']).then(L.bind(function(data) {
            var enabled = E('input', {'type':'checkbox', 'id':'privacy-registration-enabled'});
            enabled.checked = data.enabled;
            var error = E('p', {'style':'color:#c00', 'role':'alert'});
            ui.showModal('自助注册 · TOTP 动态码', [
                E('p', {}, ['注册页面：', E('a', {'href':data.enrollment_url, 'target':'_blank', 'rel':'noreferrer'}, data.enrollment_url)]),
                E('p', {}, E('label', {'for':'privacy-registration-enabled'}, [enabled, ' 允许设备通过动态码自助注册为普通组'])),
                E('p', {}, '在认证器中手动添加设置密钥，类型选“基于时间”。算法 SHA-1、6 位数字、每 30 秒更新。请仅由管理员保存密钥。'),
                E('input', {'type':'text', 'readonly':true, 'value':data.secret, 'aria-label':'TOTP 设置密钥', 'style':'width:100%;font-family:monospace'}),
                E('p', {}, E('a', {'href':data.provisioning_uri}, '在本机认证器中添加')),
                E('p', {}, ['当前动态码：', E('strong', {'style':'font:28px monospace;letter-spacing:6px'}, data.current_code), '（剩余约 ' + data.expires_in + ' 秒）']),
                E('p', {'class':'cbi-section-descr'}, '同一动态码只能成功注册一台设备。使用过的码请等下一轮；登录页只需输入动态验证码；私有 MAC 变化后需重新注册。'),
                error,
                E('div', {'class':'right'}, [
                    E('button', {'class':'btn', 'click':function(){ui.hideModal();}}, '关闭'), ' ',
                    E('button', {'class':'btn cbi-button-action', 'click':L.bind(function(){return this.registrationSettings();},this)}, '刷新动态码'), ' ',
                    E('button', {'class':'btn cbi-button-positive', 'click':L.bind(function(){
                        return this.run(['registration-enable',enabled.checked?'1':'0']).then(L.bind(this.registrationSettings,this)).catch(function(e){error.textContent=e.message;});
                    },this)}, '保存开关')
                ]),
                E('p', {}, E('button', {'class':'btn cbi-button-negative', 'click':L.bind(function(){
                    ui.showModal('重置 TOTP 密钥', [
                        E('p', {}, '重置后，原认证器的动态码立即失效，需要重新添加新的设置密钥。'),
                        E('div', {'class':'right'}, [
                            E('button', {'class':'btn','click':L.bind(this.registrationSettings,this)}, '取消'), ' ',
                            E('button', {'class':'btn cbi-button-negative','click':L.bind(function(){
                                return this.run(['registration-reset']).then(L.bind(this.registrationSettings,this));
                            },this)}, '确认重置')
                        ])
                    ]);
                },this)}, '重置设置密钥'))
            ]);
        },this));
    },

    edit: function(device) {
        var existing = !!device && !!device.configured;
        var mac = E('input', {
            'type':'text', 'id':'privacy-access-mac', 'value':device ? device.mac : '',
            'placeholder':'AA:BB:CC:DD:EE:FF', 'disabled':existing ? true : null,
            'maxlength':17, 'style':'width:100%'
        });
        var remark = E('input', {
            'type':'text', 'id':'privacy-access-name', 'value':device ? (device.remark || device.name || '') : '',
            'placeholder':'可选，例如：我的游戏电脑', 'maxlength':80, 'style':'width:100%'
        });
        var hostname = E('span', {'id':'privacy-access-hostname'}, device && device.hostname || '设备尚未提供名称');
        var owner = E('input', {'type':'text','id':'privacy-access-owner','value':device && device.owner || '',
            'placeholder':'例如：双帆；留空放入未分组','maxlength':24,'list':'privacy-access-owners','style':'width:100%'});
        var owners = devices.owners(this.data);
        var enabled = E('input', {'type':'checkbox', 'id':'privacy-access-enabled'});
        enabled.checked = !device || !device.configured || device.enabled !== false;
        var group = E('select', {'id':'privacy-access-group', 'style':'width:100%'}, [
            E('option', {'value':'normal'}, this.data.ca_required===false?'普通设备 · HTTPS 端到端，无需证书':'普通设备 · 必须信任路由器证书'),
            E('option', {'value':'iot'}, 'IoT · TCP 重建后直连')
        ]);
        group.value = device && device.group === 'iot' ? 'iot' : 'normal';
        var hint = E('p', {'class':'pa-overwrite', 'role':'status'});
        var error = E('p', {'style':'color:#c00', 'role':'alert'});
        var detectedName = device && device.hostname || '';
        var save = E('button', {
            'class':'btn cbi-button cbi-button-positive pa-action',
            'click':L.bind(function() {
                var value = normalizeMac(mac.value);
                if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(value) ||
                    value === '00:00:00:00:00:00' || (parseInt(value.slice(0,2),16) & 1)) {
                    error.textContent = '请输入有效的设备 MAC 地址。';
                    return;
                }
                save.disabled = true;
                error.textContent = '';
                return this.run(['add', value, remark.value.trim(), group.value, enabled.checked ? '1':'0', detectedName, owner.value.trim()])
                    .then(L.bind(function() { ui.hideModal(); return this.refresh(); }, this))
                    .then(function() { ui.addNotification(null, E('p', {}, '设备设置已保存并立即应用；同一 MAC 只保留一条记录。'), 'info'); })
                    .catch(function(err) { error.textContent = err.message; })
                    .finally(function() { save.disabled = false; });
            }, this)
        }, existing ? '更新并应用' : '保存并应用');
        var lookup = L.bind(function() {
            var value = normalizeMac(mac.value);
            var match = (this.data.devices || []).concat(this.data.unregistered || []).filter(function(d) {
                return normalizeMac(d.mac) === value;
            })[0];
            detectedName = match && match.hostname || '';
            hostname.textContent = detectedName || '设备尚未提供名称';
            if (match && match.configured) {
                remark.value = match.remark || match.name || '';
                group.value = match.group === 'iot' ? 'iot' : 'normal';
                enabled.checked = match.enabled !== false;
                owner.value = match.owner || '';
                hint.textContent = '此 MAC 已有记录，已载入原设置。保存会覆盖原备注、分组和启用状态。';
                save.textContent = '覆盖并应用';
            } else {
                hint.textContent = '同一 MAC 已存在时会覆盖更新，不会新增重复记录。';
                save.textContent = '保存并应用';
            }
        }, this);
        if (!existing) mac.addEventListener('change', lookup);
        ui.showModal(existing ? '编辑设备授权' : '添加或覆盖 MAC 授权', [
            E('p', {}, '请使用设备在此 Wi-Fi 或网口实际使用的 MAC；手机私有 MAC 变化后需更新授权。'),
            E('p', {}, [E('label', {'for':'privacy-access-mac'}, 'MAC 地址'), mac]),
            E('p', {}, [E('label', {'for':'privacy-access-hostname'}, '设备名称（最近上报）'), E('br'), hostname]),
            E('p', {}, [E('label', {'for':'privacy-access-name'}, '备注（可选）'), remark]),
            E('p', {}, [E('label', {'for':'privacy-access-owner'}, '所属人员 / 文件夹'), owner,
                E('datalist',{'id':'privacy-access-owners'},owners.map(function(n){return E('option',{'value':n},n);})),
                E('small',{},'仅用于整理列表，不改变普通 / IoT 分流或上网权限。')]),
            E('p', {}, E('label', {'for':'privacy-access-enabled'}, [enabled, ' 允许上网'])),
            E('p', {}, [E('label', {'for':'privacy-access-group'}, '设备分组'), group]),
            E('p', {'class':'cbi-section-descr'}, this.data.ca_required===false?'所有设备的 HTTPS 均端到端加密，不解密、不改写加密内容；IoT 通过路由器重建 TCP 后直连。':'普通组需安装并信任路由器 CA；IoT 组无需证书，使用现有 IoT 代理。'),
            hint, error,
            E('div', {'class':'right'}, [
                E('button', {'class':'btn', 'click':function() { ui.hideModal(); }}, '取消'), ' ', save
            ])
        ]);
        if (!existing) lookup();
    },

    remove: function(device) {
        var error = E('p', {'style':'color:#c00', 'role':'alert'});
        var button = E('button', {
            'class':'btn cbi-button cbi-button-negative',
            'click':L.bind(function() {
                button.disabled = true;
                return this.run(['remove', device.mac]).then(L.bind(function() {
                    ui.hideModal(); return this.refresh();
                }, this)).catch(function(err) { error.textContent = err.message; button.disabled = false; });
            }, this)
        }, '删除授权');
        ui.showModal('删除 MAC 授权', [
            E('p', {}, '删除 ' + (device.remark || device.name || device.hostname || device.mac) + ' 的授权？删除后将立即失去外网权限。'),
            error,
            E('div', {'class':'right'}, [E('button', {'class':'btn', 'click':function() { ui.hideModal(); }}, '取消'), ' ', button])
        ]);
    },

    buildContent: function(data) {
        var readonly = !data.can_write;
        var groups = this.partition(data);
        var makeRow = L.bind(function(d) {
            var auth = d.configured && d.enabled ? (d.allowed ? '已授权':'已授权 · 策略待应用')
                : (d.configured ? '已停用 · 外网阻断':'未授权 · 外网阻断');
            var state = d.connected ? '已连接 · ' + (d.connection === 'wifi' ? 'Wi-Fi':'有线') : '未连接';
            var actions = readonly ? '只读' : E('div', {'class':'pd-actions'}, [
                E('button', {'class':'btn cbi-button cbi-button-action pa-action',
                    'click':L.bind(function() { this.edit(d); }, this)}, d.configured ? '编辑':'添加 MAC 授权'),
                d.configured ? ' ' : null,
                d.configured ? E('button', {'class':'btn cbi-button-negative',
                    'click':L.bind(this.remove, this, d)}, '删除') : null
            ]);
            return [
                devices.identity(d),
                E('div', {}, [E('div', {'class':'pd-id'}, d.mac), E('div', {'class':'pd-ip'}, (d.ips || []).join(', ') || '暂无 IP')]),
                E('div', {}, [E('div', {}, state), E('div', {'class':d.configured && d.enabled ? 'pa-allowed':'pa-blocked'}, auth)]),
                d.configured ? (d.group === 'iot' ? 'IoT':data.ca_required===false?'普通 · HTTPS 透传':'普通 · 证书') : '待授权',
                actions
            ];
        }, this);
        var titles = ['已连接的未授权设备', '已连接的已授权设备', '已授权设备（未连接）'];
        var empties = ['当前没有已连接的未授权设备。', '当前没有已连接的已授权设备。', '暂无未连接的授权记录。'];
        this.folderState=this.folderState||{};
        var sections=devices.browser({state:this.folderState,data:data,canWrite:!readonly,emptyIndex:1,run:this.run.bind(this),refresh:this.refresh.bind(this),headers:['备注 / 设备名称','MAC / IP','连接 / 授权','分流分组','操作'],row:makeRow,
            sections:groups.map(function(all,index){return {title:titles[index],devices:all,empty:empties[index]};})});
        return E('div', {'class':'cbi-map privacy-access-page'}, [
            E('style', {}, '.privacy-access-page table.table{display:table!important;width:100%!important;min-width:760px}.privacy-access-page table.table .tr{display:table-row!important}.privacy-access-page table.table .th,.privacy-access-page table.table .td{display:table-cell!important;width:auto!important;vertical-align:middle}.privacy-access-page .table-titles th{background:#f1f5f9;color:#111827;font-weight:600}.privacy-access-page .pa-action:not(:disabled){background:#2563eb!important;color:#fff!important;border:1px solid #2563eb!important;opacity:1!important;cursor:pointer}.privacy-access-page .pa-action:disabled{opacity:.45!important;cursor:not-allowed}.privacy-access-page .pa-action:not(:disabled):hover{background:#1d4ed8!important}.privacy-access-page .pa-id{font-family:monospace;white-space:nowrap}.privacy-access-page .pa-ip{color:#64748b;margin-top:.25em}.privacy-access-page .pa-allowed{color:#15803d}.privacy-access-page .pa-blocked{color:#b45309}.privacy-access-page .pa-hostname{font-weight:600}'),
            E('h2', {}, '设备上网白名单'),
            E('p',{},data.ca_required===false?'当前方案：HTTPS 端到端透传 · 无 MITM · 无需安装路由器 CA':'当前方案：HTTPS 解密 · 需要信任路由器 CA'),
            devices.style(),
            E('p', {'class':'cbi-section-descr'}, '只有已启用的 MAC 白名单设备可以上网。备注优先显示，设备名称保留在下方；在“编辑”中设置所属人员，即可按人折叠，两个管理页面共用。人员文件夹不改变普通 / IoT 分流。'),
            data.policy_running ? E('p', {}, '严格 MAC 白名单策略正在运行。') : E('p', {'style':'color:#c00'}, '白名单策略未运行，请检查服务。'),
            E('div', {'style':'margin:1em 0'}, [
                E('button', {'class':'btn cbi-button-positive pa-action', 'disabled':readonly ? true:null,
                    'click':L.bind(function() { this.edit(null); }, this)}, '手动添加 MAC'), ' ',
                E('button', {'class':'btn cbi-button cbi-button-action pa-action',
                    'click':ui.createHandlerFn(this, 'refresh')}, '刷新设备列表'), ' ',
                readonly ? null : E('button', {'class':'btn cbi-button-action pa-action',
                    'click':ui.createHandlerFn(this, 'registrationSettings')}, '自助注册设置')
            ]),
            sections,
            E('p', {'class':'cbi-section-descr'}, 'Wi-Fi 按关联状态判断；有线按最近 2 分钟的活动判断。有效 DHCP 租约不等同于已连接。未连接区保留已停用的授权记录，方便重新编辑。'),
            data.migration_pending ? E('p', {'style':'color:#b45309;margin-top:1em'},
                '待补充 MAC 的旧授权（当前不放行）：' + data.migration_pending) : E('span')
        ]);
    },

    render: function(data) {
        this.data = data;
        this.content = E('div', {}, this.buildContent(data));
        return this.content;
    }
});
