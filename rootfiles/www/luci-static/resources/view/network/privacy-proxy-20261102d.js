'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require request';
'require privacy-devices-20261021b as devices';

var callAccess=rpc.declare({object:'session',method:'access',params:['scope','object','function'],expect:{access:false}});
return view.extend({
    handleSaveApply:null,handleSave:null,handleReset:null,
    load:function(){
        return Promise.all([fs.exec('/usr/sbin/privacy-proxy-status',[]),callAccess('file','/usr/sbin/privacy-proxy','exec')]).then(function(r){
            if(r[0].code!==0)throw new Error(r[0].stderr||'无法读取代理状态');
            var data=JSON.parse(r[0].stdout);data.can_write=r[1]===true;return data;
        });
    },
    run:function(args){return fs.exec('/usr/sbin/privacy-proxy',args).then(function(r){if(r.code!==0)throw new Error(r.stderr||'操作失败');return JSON.parse(r.stdout);});},
    refresh:function(){return this.load().then(L.bind(function(d){this.data=d;this.content.replaceChildren(this.build(d));},this));},
    act:function(button,args){
        button.disabled=true;
        return this.run(args).then(L.bind(this.refresh,this)).catch(function(e){ui.addNotification(null,E('p',{},e.message),'error');}).finally(function(){button.disabled=false;});
    },
    upload:function(filter){
        var self=this,path=null;
        var file=E('input',{'type':'file','id':'pp-local-file','style':'width:100%;min-height:46px'});
        var rules=E('input',{'type':'checkbox','id':'pp-local-rules'});rules.checked=true;
        var error=E('p',{'role':'alert','style':'color:#b91c1c'});
        var discard=function(){var p=path;path=null;return p?self.run(['discard-upload',p]).catch(function(){}):Promise.resolve();};
        var cancel=function(){return discard().then(function(){ui.hideModal();});};
        var next=E('button',{'class':'btn cbi-button-positive','click':function(){
            var chosen=file.files&&file.files[0];
            if(!chosen||chosen.size===0||chosen.size>2097152){error.textContent='请选择不超过 2MB 的非空配置文件；不要求扩展名。';return;}
            next.disabled=true;close.disabled=true;error.textContent='正在上传并离线校验…';
            var withRules=rules.checked?'1':'0';
            return self.run(['prepare-upload']).then(function(r){
                path=r.path;
                var body=new FormData();body.append('sessionid',rpc.getSessionID());body.append('filename',path);body.append('filedata',chosen);
                return request.post(L.env.cgi_base+'/cgi-upload',body,{timeout:60000});
            }).then(function(response){
                var r=response.json();if(!r||r.failure)throw new Error('文件上传失败，请重新选择。');
                return self.run(['preview-file',path,filter,withRules]);
            }).then(function(r){
                var message=E('p',{'role':'alert','style':'color:#b91c1c'});
                var apply=E('button',{'class':'btn cbi-button-positive','click':function(){
                    apply.disabled=true;back.disabled=true;
                    return self.run(['import-file',path,filter,withRules,r.sha256]).then(function(result){
                        path=null;ui.hideModal();ui.addNotification(null,E('p',{},'本地导入成功：'+result.count+' 个节点。已暂停定时节点订阅更新，避免覆盖本地配置。'),'info');return self.refresh();
                    }).catch(function(e){path=null;message.textContent=e.message+' 请关闭后重新上传。';back.disabled=false;});
                }},'确认替换节点');
                var back=E('button',{'class':'btn','click':cancel},'取消并删除上传文件');
                ui.showModal('本地配置预览',[
                    E('p',{},'文件：'+chosen.name),
                    E('p',{},r.count+' 个兼容节点 · 香港 '+r.hk+' 个 · 跳过 '+r.skipped+' 个不支持节点'),
                    E('p',{},withRules==='1'?'导入 '+r.rules+' 条内嵌兼容规则，跳过 '+r.rule_skipped+' 个不支持规则/外部提供器。':'保留路由器现有分流规则。'),
                    E('p',{},r.insecure?r.insecure+' 个节点在文件中设置了跳过服务端证书验证，请确认你信任该配置来源。':'节点未设置跳过服务端证书验证。'),
                    E('p',{},'确认后会短暂重载代理。原订阅链接保留，但暂停定时节点更新；手动“保存并更新订阅”成功后才恢复。不会修改设备授权、所属人员或 IoT 直连规则。'),
                    message,E('div',{'class':'right'},[back,' ',apply])
                ]);
            }).catch(function(e){return discard().then(function(){error.textContent=e.message;next.disabled=false;close.disabled=false;});});
        }},'上传并预览');
        var close=E('button',{'class':'btn','click':cancel},'取消');
        ui.showModal('从本地导入 FlClash / Clash 配置',[
            E('p',{},'支持无扩展名、YAML 或 JSON，最大 2MB。按内容识别，不需要能访问订阅。先预览，再确认替换；失败保留原配置。'),
            E('label',{'for':'pp-local-file'},'选择配置文件'),file,
            E('p',{},E('label',{'for':'pp-local-rules'},[rules,' 同时导入文件内嵌的兼容分流规则'])),
            E('p',{},'只提取受支持节点及规则；不执行脚本，不采用文件的监听端口、DNS 或代理组，也不下载外部 provider。名称筛选沿用页面当前输入。'),
            error,E('div',{'class':'right'},[close,' ',next])
        ]);
    },
    temporary:function(d){
        var duration=E('select',{'id':'pp-duration','style':'width:100%'},[15,30,60,120,240,1440,0].map(function(n){return E('option',{'value':n},n===0?'长期（不自动恢复）':n===1440?'24 小时':n+' 分钟');}));duration.value=d.proxy_permanent?'0':'60';
        var mode=E('select',{'id':'pp-mode','style':'width:100%'},[
            E('option',{'value':'rule'},'规则：国内直连，其他按规则/所选节点'),E('option',{'value':'global'},'全局：所有可放行的外网 TCP 走代理')]);mode.value=d.proxy_mode||'global';
        var node=E('select',{'id':'pp-node','style':'width:100%'},[
            E('option',{'value':'privacy-auto'},'共用自动低延时节点')
        ].concat((this.data.nodes||[]).map(function(n){return E('option',{'value':n.tag},n.tag+' · '+(n.delay>0?n.delay+' ms':'未测/不可用'));})));node.value=this.data.selected||'privacy-auto';
        var error=E('p',{'role':'alert','style':'color:#b91c1c'});
        var save=E('button',{'class':'btn cbi-button-positive','click':L.bind(function(){
            save.disabled=true;return this.run(['temporary',d.mac,duration.value,mode.value,node.value]).then(L.bind(function(){ui.hideModal();return this.refresh();},this)).catch(function(e){error.textContent=e.message;save.disabled=false;});
        },this)},'保存设备代理');
        ui.showModal('设备临时代理',[
            devices.identity(d),E('p',{'class':'pd-id'},d.mac),
            E('p',{},'时长和模式只修改这台设备，白名单分组不变。节点由全部临时代理设备共用：最后一次选择生效，并同步其他设备；IoT 通过路由器重建 TCP 后直连。'),
            E('p',{},this.data.ca_required===false?'规则模式国内流量直连，其他按规则/共用节点；HTTPS 保持端到端，不解密、不改写内部 UA，无需 CA。DNS/NTP、外部 UDP/QUIC 和 IPv6 的原限制保留。':'规则模式国内 HTTPS 仍先解密、统一 UA 再直连；其余域名先用代理内加密 DNS 解析。普通设备仍需信任原 CA。DNS/NTP 保留，其他外部 UDP、QUIC 和 IPv6 继续阻断。'),
            E('p',{},'长期跨重启保留；定时按原截止时间恢复。节点切换会断开旧出口连接；新增设备或修改模式可能短暂重载代理。'),
            E('p',{},[E('label',{'for':'pp-duration'},'持续时间'),duration]),
            E('p',{},[E('label',{'for':'pp-mode'},'分流模式'),mode]),
            E('p',{},[E('label',{'for':'pp-node'},'所有临时代理设备的共用节点（按延时排序）'),node]),error,
            E('div',{'class':'right'},[E('button',{'class':'btn','click':function(){ui.hideModal();}},'取消'),' ',save])
        ]);
    },
    build:function(d){
        var readonly=!d.can_write,self=this;this.data=d;
        var selected=E('select',{'aria-label':'出口节点','style':'width:100%;max-width:560px','disabled':readonly?true:null},[
            E('option',{'value':'privacy-auto'},'自动选择低延时节点'+(d.auto_node?'（当前 '+d.auto_node+'）':''))
        ].concat((d.nodes||[]).map(function(n){return E('option',{'value':n.tag},n.tag+' · '+n.type+(n.delay?' · '+n.delay+' ms':'')+(n.insecure?' · 跳过服务端证书验证':''));})));
        selected.value=d.selected||'privacy-auto';
        var switchButton=E('button',{'class':'btn cbi-button-positive','disabled':readonly?true:null,'click':function(){return self.act(switchButton,['select',selected.value]);}},'切换节点');
        var testButton=E('button',{'class':'btn cbi-button-action','disabled':readonly?true:null,'click':function(){
            testButton.disabled=true;return self.run(['test',selected.value]).then(function(r){ui.addNotification(null,E('p',{},'所选节点 HTTPS 响应：'+r.delay+' ms（不是下载速度测试）。'),'info');}).catch(function(e){ui.addNotification(null,E('p',{},e.message),'error');}).finally(function(){testButton.disabled=false;});
        }},'测试所选节点');
        var testAll=E('button',{'class':'btn','disabled':readonly?true:null,'click':function(){return self.act(testAll,['test-all']);}},'批量探测并按延时排序');
        var ruleUrl=E('input',{'id':'pp-rule-url','type':'password','autocomplete':'new-password','maxlength':4096,'placeholder':d.rule_url_configured?'已配置独立规则链接；不修改请直接点更新':'可选：Clash / sing-box 规则 HTTPS 链接','style':'width:100%','disabled':readonly?true:null});
        var ruleSave=E('button',{'class':'btn','disabled':readonly?true:null,'click':function(){return self.act(ruleSave,['save-rules',ruleUrl.value.trim()]);}},'保存规则链接（空值改为跟随节点订阅）');
        var ruleUpdate=E('button',{'class':'btn cbi-button-positive','disabled':readonly?true:null,'click':function(){return self.act(ruleUpdate,['update-rules']);}},'更新分流规则');
        var url=E('input',{'id':'privacy-proxy-url','type':'password','autocomplete':'new-password','maxlength':4096,'placeholder':d.subscription_configured?'已配置 '+d.subscription_host+'；留空保留原链接':'粘贴 HTTPS 订阅链接','style':'width:100%','disabled':readonly?true:null});
        var filter=E('input',{'id':'privacy-proxy-filter','type':'text','maxlength':120,'value':d.filter||'','placeholder':'留空导入全部；多个关键词用 | 分隔','style':'width:100%','disabled':readonly?true:null});
        var saveButton=E('button',{'class':'btn','disabled':readonly?true:null,'click':function(){return self.act(saveButton,['save-subscription',url.value.trim(),filter.value.trim()]);}},'仅保存订阅设置');
        var updateButton=E('button',{'class':'btn cbi-button-positive','disabled':readonly?true:null,'click':function(){
            ui.showModal('更新代理订阅',[
                E('p',{},'下载并校验节点后重载代理，IoT 和临时代理设备的连接可能短暂重连。失败时保留原节点；不调整真实设备的授权和分组。'),
                E('div',{'class':'right'},[E('button',{'class':'btn','click':function(){ui.hideModal();}},'取消'),' ',E('button',{'class':'btn cbi-button-positive','click':function(event){
                    var b=event.currentTarget;b.disabled=true;
                    return self.run(['save-subscription',url.value.trim(),filter.value.trim()]).then(function(){return self.run(['update-remote']);}).then(function(r){ui.hideModal();ui.addNotification(null,E('p',{},'已导入 '+r.count+' 个节点；跳过 '+r.skipped+' 个不支持的条目。'),'info');return self.refresh();}).catch(function(e){ui.hideModal();ui.addNotification(null,E('p',{},e.message),'error');});
                }},'确认更新')])
            ]);
        }},'保存并更新订阅');
        var makeRow=function(device){
            var active=device.enabled&&device.group==='normal'&&(device.proxy_active||device.proxy_remaining>0);
            var actions='—';
            if(!readonly&&device.enabled&&device.group==='normal')actions=E('div',{'class':'pd-actions'},[
                E('button',{'class':'btn cbi-button-action','click':function(){self.temporary(device);}},active?'修改代理设置':'临时走代理')
            ].concat(active?[' ',E('button',{'class':'btn cbi-button-negative','click':function(event){return self.act(event.currentTarget,['cancel',device.mac]);}},'立即恢复')]:[]));
            return [devices.identity(device),
                E('div',{},[E('div',{'class':'pd-id'},device.mac),E('div',{'class':'pd-ip'},(device.ips||[]).join(', ')||'暂无 IP')]),
                E('div',{'class':'pd-path'},!device.enabled?'已停用':device.group==='iot'?'IoT · TCP 重建直连':active?(device.proxy_permanent?'长期':'剩余 '+Math.ceil(device.proxy_remaining/60)+' 分钟')+' · '+(device.proxy_mode==='rule'?'规则':'全局')+' · 共用 '+(d.selected==='privacy-auto'?'自动':d.selected||'自动'):(d.ca_required===false?'普通 · HTTPS 端到端透传':'普通 · 原证书路径')),
                device.connected?'已连接':'未连接',actions];
        };
        this.folderState=this.folderState||{};
        var deviceList=devices.browser({state:this.folderState,data:d,canWrite:!readonly,run:this.run.bind(this),refresh:this.refresh.bind(this),headers:['备注 / 设备名称','MAC / IP','当前路径','连接','操作'],row:makeRow,sections:[
            {title:'已连接的已授权设备',devices:(d.devices||[]).filter(function(x){return x.enabled&&x.connected;})},
            {title:'已授权设备（未连接）',devices:(d.devices||[]).filter(function(x){return x.enabled&&!x.connected;})},
            {title:'已停用设备',devices:(d.devices||[]).filter(function(x){return !x.enabled;})}
        ]});
        return E('div',{'class':'cbi-map privacy-proxy-page'},[
            E('style',{},'.privacy-proxy-page .pp-box{margin:18px 0;padding:16px;border:1px solid #d1d5db}.privacy-proxy-page label{display:block;margin:12px 0 4px}.privacy-proxy-page input,.privacy-proxy-page select{min-height:40px;font-size:16px}.privacy-proxy-page table{display:table!important;min-width:760px;width:100%}.privacy-proxy-page tr{display:table-row!important}.privacy-proxy-page td,.privacy-proxy-page th{display:table-cell!important;padding:10px 8px;border-bottom:1px solid #ddd}.privacy-proxy-page .btn{margin:4px 4px 4px 0}'),
            devices.style(),
            E('h2',{},'代理与临时分流'),
            E('p',{},d.ca_required===false?'当前方案：HTTPS 端到端透传 · 无 MITM · 不需要路由器 CA':'当前方案：HTTPS 解密 · 需信任路由器 CA'),
            E('p',{},'IoT 通过路由器重建 TCP 后直连，不使用远端代理。全部临时代理设备共用一个全地区出口，最后一次选择会同步覆盖旧节点；时长和规则/全局模式仍按设备独立设置。'),
            E('p',{},'出口分为直连与手动代理两类，不等于上游只能识别三台设备；TLS、应用和流量时序仍可能有差异，不能保证检测结果。'),
            E('p',{},'IoT 路径：设备 → 路由器 TCP 中继 → 目标服务'),
            E('p',{'style':d.running&&d.available_nodes>0?'color:#15803d':'color:#b45309'},d.running?(d.available_nodes>0?'代理运行中 · '+d.available_nodes+' 个节点有成功测速记录':'内核运行中，但暂无成功测速记录：请测试节点或更新订阅。'):'代理未就绪：请检查配置；不会自动回退为直连'),
            E('button',{'class':'btn','click':ui.createHandlerFn(this,'refresh')},'刷新状态'),
            E('div',{'class':'pp-box'},[E('h3',{},'所有临时代理设备的共用出口节点'),selected,E('p',{},[switchButton,' ',testButton,' ',testAll]),
                E('p',{'class':'cbi-section-descr'},'切换节点无需重启内核，但现有代理连接可能重连。显示的延时来自历史 HTTPS 探测；不代表所有网站或游戏的延时。')]),
            E('div',{'class':'pp-box'},[E('h3',{},'订阅设置'),E('label',{'for':'privacy-proxy-url'},'HTTPS 订阅链接（留空保留现有链接）'),url,
                E('label',{'for':'privacy-proxy-filter'},'节点名称筛选'),filter,E('p',{},[saveButton,' ',updateButton]),
                E('p',{'class':'cbi-section-descr'},'支持 sing-box、Clash YAML/JSON、常见节点链接及 Base64。名称筛选留空导入所有地区。只提取兼容节点/分流数据，远端监听、DNS、脚本不能接管路由器。使用订阅来源时每周一 04:00 自动更新。'),
                E('p',{},d.source==='file'?'当前来源：本地文件 · 定时节点更新已暂停（仅保存链接不会恢复）。':'当前来源：订阅 · 每周一 04:00 自动更新节点。'),
                E('p',{},d.updated_at?'最近更新：'+new Date(d.updated_at*1000).toLocaleString():'当前沿用原有节点；尚未在此页更新订阅。')]),
            E('div',{'class':'pp-box'},[E('h3',{},'本地配置导入'),
                E('p',{},'节点失效、路由器无法下载订阅时，可从电脑或手机上传 FlClash / Clash 配置，支持无后缀文件。上传内容只在路由器本地解析。'),
                E('button',{'class':'btn cbi-button-positive','disabled':readonly?true:null,'click':function(){self.upload(filter.value.trim());}},'上传本地配置文件')]),
            d.insecure_nodes?E('p',{'style':'color:#b45309'},'注意：'+d.insecure_nodes+' 个节点的原配置设置了“跳过服务端证书验证”。本页没有新增该设置，建议向节点提供方确认。'):E('span'),
            E('div',{'class':'pp-box'},[E('h3',{},'规则模式'),
                E('p',{},(d.cn_ready?'国内域名/IP 规则已就绪':'国内规则尚未准备，请先更新')+'；额外导入 '+(d.rule_count||0)+' 条规则，跳过 '+(d.rule_skipped||0)+' 个不支持条目/提供器。'),
                E('p',{},'已知国内域名优先直连；其余通过共用代理的加密 DNS 解析后判断国内 IP，再按兼容规则 DIRECT / REJECT / 共用代理处理。规则按模式合并，避免随设备数重复展开。支持域名/IP、GEOIP/GEOSITE CN、MATCH 和 HTTPS Clash domain/ipcidr/classical 提供器，不支持 MRS、脚本或完整 Clash 语义。'),
                E('label',{'for':'pp-rule-url'},'独立规则订阅（可选，输入后先保存）'),ruleUrl,E('p',{},[ruleSave,' ',ruleUpdate])]),
            E('h3',{},'设备临时代理'),
            E('p',{},'仅限已授权普通设备；长期/定时和规则/全局独立设置，节点全体同步。未授权设备不放行；IoT 默认直连，不使用远端代理。'),
            E('p',{'class':'cbi-section-descr'},'可新建/管理人员分组，也可单台或批量移动；只整理列表，不改变普通 / IoT 分流。'),deviceList,
            E('p',{},E('a',{'href':L.url('admin/network/privacy_access')},'管理设备白名单'))
        ]);
    },
    render:function(d){this.data=d;this.content=E('div',{},this.build(d));return this.content;}
});
