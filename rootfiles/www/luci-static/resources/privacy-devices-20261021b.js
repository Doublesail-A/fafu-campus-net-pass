'use strict';
'require baseclass';
'require ui';

return baseclass.extend({
    owners:function(data){
        return Array.from(new Set((data.owners||[]).concat((data.devices||[]).map(function(d){return d.owner||'';})).filter(Boolean))).sort(function(a,b){return a.localeCompare(b,'zh-CN');});
    },
    changeName:function(options,old){
        var input=E('input',{'type':'text','maxlength':24,'aria-label':'分组名称','value':old||'','style':'width:100%;min-height:42px;font-size:16px','placeholder':'例如：双帆'});
        var error=E('p',{'role':'alert','style':'color:#b91c1c'});
        var save=E('button',{'class':'btn cbi-button-positive','click':function(){
            var value=input.value.trim();if(!value||value==='未分组'){error.textContent='请输入分组名称，不能使用“未分组”。';return;}
            save.disabled=true;
            return options.run(old?['people-rename',old,value]:['people-add',value]).then(function(){ui.hideModal();return options.refresh();}).catch(function(e){error.textContent=e.message;save.disabled=false;});
        }},old?'保存新名称':'新建分组');
        ui.showModal(old?'重命名分组':'新建人员分组',[
            E('p',{},'分组仅整理设备，不改变上网权限或普通 / IoT 分流。新建分组可以暂时没有设备。'),
            E('label',{},'分组名称'),input,error,
            E('div',{'class':'right'},[E('button',{'class':'btn','click':function(){ui.hideModal();}},'取消'),' ',save])
        ]);
    },
    manage:function(options){
        var self=this,names=this.owners(options.data);
        ui.showModal('管理人员分组',[
            E('p',{},'重命名会同步组内全部设备；删除分组只把设备移回“未分组”，不会删除授权。'),
            E('button',{'class':'btn cbi-button-positive','click':function(){self.changeName(options);}},'新建分组'),
            E('div',{},names.length?names.map(function(owner){
                var count=(options.data.devices||[]).filter(function(d){return d.owner===owner;}).length;
                return E('div',{'class':'pd-tools'},[
                    E('strong',{'style':'flex:1;overflow-wrap:anywhere'},owner+'（'+count+' 台）'),
                    E('button',{'class':'btn','click':function(){self.move(options,null,owner);}},'移入设备'),
                    E('button',{'class':'btn','click':function(){self.changeName(options,owner);}},'重命名'),
                    E('button',{'class':'btn cbi-button-negative','click':function(){
                        var error=E('p',{'role':'alert','style':'color:#b91c1c'});
                        var remove=E('button',{'class':'btn cbi-button-negative','click':function(){
                            remove.disabled=true;return options.run(['people-remove',owner]).then(function(){ui.hideModal();return options.refresh();}).catch(function(e){error.textContent=e.message;remove.disabled=false;});
                        }},'删除分组');
                        ui.showModal('删除分组',[
                            E('p',{},'删除“'+owner+'”？'+count+' 台设备将移至未分组；所有设备授权、备注与代理设置保留。'),error,
                            E('div',{'class':'right'},[E('button',{'class':'btn','click':function(){self.manage(options);}},'取消'),' ',remove])
                        ]);
                    }},'删除分组')
                ]);
            }):[E('p',{},'尚无人员分组，请先新建。')]),
            E('div',{'class':'right'},E('button',{'class':'btn','click':function(){ui.hideModal();}},'关闭'))
        ]);
    },
    move:function(options,single,destination){
        var self=this,selected=Object.create(null),names=this.owners(options.data);
        var eligible=(options.data.devices||[]).filter(function(d){return d.configured!==false;}).sort(this.compare.bind(this));
        if(single)selected[single.mac]=true;
        var target=E('select',{'aria-label':'目标分组','style':'width:100%;min-height:42px;font-size:16px'},[
            E('option',{'value':''},'未分组')
        ].concat(names.map(function(n){return E('option',{'value':n},n);})));
        target.value=destination!==undefined?destination:single&&single.owner||'';
        var search=E('input',{'type':'search','aria-label':'搜索待移动设备','placeholder':'搜索备注、人员、设备名、MAC','style':'width:100%;min-height:42px;font-size:16px'});
        var list=E('div',{'class':'pd-picker','style':'max-height:46vh;overflow:auto;border:1px solid #cbd5e1;padding:8px'});
        var count=E('p',{'role':'status'}),error=E('p',{'role':'alert','style':'color:#b91c1c'});
        var update=function(){count.textContent='已选择 '+Object.keys(selected).length+' 台设备';};
        var render=function(){
            var q=search.value.trim().toLowerCase();
            var visible=eligible.filter(function(d){return self.matches(d,q);});
            list.replaceChildren.apply(list,visible.length?visible.map(function(d){
                var check=E('input',{'type':'checkbox','aria-label':'选择 '+self.title(d),'style':'width:18px;height:18px;min-height:0;flex:none;margin:4px 8px 0 0'});check.checked=!!selected[d.mac];
                check.addEventListener('change',function(){if(check.checked)selected[d.mac]=true;else delete selected[d.mac];update();});
                return E('label',{'style':'display:flex;align-items:flex-start;padding:10px 4px;border-bottom:1px solid #e2e8f0;margin:0'},[
                    check,E('div',{},[self.identity(d),E('span',{'class':'pd-id'},d.mac+' · '+(d.owner||'未分组'))])
                ]);
            }):[E('p',{},'没有匹配的设备。')]);update();
        };
        search.addEventListener('input',render);render();
        var save=E('button',{'class':'btn cbi-button-positive','click':function(){
            var macs=Object.keys(selected);if(!macs.length){error.textContent='请至少选择一台设备。';return;}
            if(macs.length>128){error.textContent='一次最多移动 128 台设备。';return;}
            save.disabled=true;
            return options.run(['people-move',target.value].concat(macs)).then(function(){ui.hideModal();return options.refresh();}).catch(function(e){error.textContent=e.message;save.disabled=false;});
        }},'移动到目标分组');
        ui.showModal(single?'移动设备分组':'批量移动设备',[
            E('p',{},'这里只整理所属人员；不改变设备授权、普通 / IoT 分流、临时代理节点或期限。'),
            E('label',{},'目标分组'),target,search,
            E('div',{'class':'pd-tools'},[
                E('button',{'class':'btn','click':function(){eligible.filter(function(d){return self.matches(d,search.value.trim().toLowerCase());}).forEach(function(d){selected[d.mac]=true;});render();}},'全选搜索结果'),
                E('button',{'class':'btn','click':function(){selected=Object.create(null);render();}},'清空选择')]),
            count,list,error,E('div',{'class':'right'},[E('button',{'class':'btn','click':function(){ui.hideModal();}},'取消'),' ',save])
        ]);
    },
    title:function(d){return d.remark||d.name||d.hostname||d.mac;},
    compare:function(a,b){return this.title(a).localeCompare(this.title(b),'zh-CN',{numeric:true})||a.mac.localeCompare(b.mac);},
    matches:function(d,q){return [d.owner,d.remark,d.name,d.hostname,d.mac].concat(d.ips||[]).join(' ').toLowerCase().indexOf(q)!==-1;},
    identity:function(d){
        return E('div',{'class':'pd-identity'},[
            E('strong',{'class':'pd-remark'},this.title(d)),
            E('span',{'class':'pd-hostname'},'设备名称：'+(d.hostname||'设备未提供名称'))
        ]);
    },
    style:function(){return E('style',{},
        '.pd-browser{margin:16px 0}.pd-tools{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:12px 0}.pd-tools input{flex:1;min-width:180px;max-width:480px;min-height:42px;font-size:16px}.pd-section{margin:20px 0}.pd-folder{margin:10px 0;border:1px solid #cbd5e1;border-radius:5px;background:var(--background-color,#fff)}.pd-folder>summary{cursor:pointer;padding:12px;font-size:16px;font-weight:600;background:rgba(100,116,139,.08);overflow-wrap:anywhere}.pd-folder>summary .pd-count{font-size:13px;font-weight:400;margin-left:12px;opacity:.8}.pd-browser table.pd-table{display:table!important;min-width:0!important;width:100%!important;border-collapse:collapse}.pd-browser table.pd-table tr{display:table-row!important}.pd-browser table.pd-table td,.pd-browser table.pd-table th{display:table-cell!important;width:auto!important;text-align:left;padding:12px 10px;vertical-align:middle;border-bottom:1px solid #dce1e7}.pd-browser .pd-table th{font-size:12px;opacity:.8}.pd-identity{min-width:150px;max-width:330px;overflow-wrap:anywhere}.pd-remark{display:block;font-size:16px;font-weight:700;line-height:1.45}.pd-hostname{display:block;font-size:12px;opacity:.65;margin-top:5px;overflow-wrap:anywhere}.pd-id{font:12px monospace;overflow-wrap:anywhere}.pd-ip{font-size:12px;opacity:.7;margin-top:4px}.pd-actions{display:flex;flex-wrap:wrap;gap:6px}.pd-actions .btn{margin:0!important}.pd-empty{padding:12px;opacity:.7}.pd-path{max-width:310px;overflow-wrap:anywhere;font-size:13px;line-height:1.6}@media(max-width:760px){.pd-browser table.pd-table,.pd-browser table.pd-table tbody{display:block!important}.pd-browser table.pd-table tr{display:grid!important;grid-template-columns:minmax(0,1fr) minmax(0,1fr);padding:10px 6px;border-bottom:1px solid #cbd5e1}.pd-browser table.pd-table tr.pd-head{display:none!important}.pd-browser table.pd-table td{display:block!important;padding:6px;border:0;min-width:0}.pd-browser table.pd-table td:first-child,.pd-browser table.pd-table td:last-child{grid-column:1/-1}.pd-browser table.pd-table td:not(:first-child):not(:last-child):before{content:attr(data-label);display:block;font-size:11px;opacity:.6;margin-bottom:4px}.pd-identity{max-width:none}.pd-remark{font-size:17px}.pd-actions .btn{min-height:40px}.pd-folder>summary .pd-count{display:block;margin:5px 0 0 15px}}');},
    browser:function(options){
        var self=this,state=options.state,q='',folders=[];
        var management={data:options.data||{devices:options.sections.reduce(function(a,s){return a.concat(s.devices);},[]),owners:[]},run:options.run,refresh:options.refresh};
        var ownerNames=this.owners(management.data);
        var search=E('input',{'type':'search','aria-label':'搜索设备','placeholder':'搜索备注、所属人员、设备名、MAC 或 IP','value':state.query||''});
        var content=E('div',{});
        var render=function(){
            q=search.value.trim().toLowerCase();state.query=search.value;folders=[];
            var sections=options.sections.map(function(section,index){
                var all=section.devices,visible=all.filter(function(d){return self.matches(d,q);});
                var byOwner=Object.create(null);
                visible.forEach(function(d){var owner=(d.owner||'').trim();(byOwner[owner]||(byOwner[owner]=[])).push(d);});
                if(index===(options.emptyIndex||0))ownerNames.forEach(function(owner){
                    if(!(management.data.devices||[]).some(function(d){return d.owner===owner;})&&owner.toLowerCase().indexOf(q)!==-1)byOwner[owner]=[];
                });
                var names=Object.keys(byOwner).sort(function(a,b){return a===''?1:b===''?-1:a.localeCompare(b,'zh-CN',{numeric:true});});
                var nodes=names.map(function(owner){
                    var devices=byOwner[owner].sort(self.compare.bind(self));
                    var key=index+'\n'+owner;
                    var connected=devices.filter(function(d){return d.connected;}).length;
                    var folder=E('details',{'class':'pd-folder'},[
                        E('summary',{},[E('span',{},owner||'未分组'),E('span',{'class':'pd-count'},devices.length+' 台 · 已连接 '+connected+' 台')]),
                        options.canWrite?E('p',{'style':'padding:0 12px'},E('button',{'class':'btn','click':function(){self.move(management,null,owner);}},'将设备移入此分组')):E('span'),
                        devices.length?E('table',{'class':'pd-table'},[
                            E('tr',{'class':'pd-head'},options.headers.map(function(h){return E('th',{'scope':'col'},h);}))
                        ].concat(devices.map(function(d){
                            var cells=options.row(d);
                            if(options.canWrite&&d.configured!==false)cells[cells.length-1]=E('div',{'class':'pd-actions'},[cells[cells.length-1],E('button',{'class':'btn','click':function(){self.move(management,d);}},'移动分组')]);
                            return E('tr',{},cells.map(function(cell,i){return E('td',{'data-label':options.headers[i]},cell);}));
                        }))):E('p',{'class':'pd-empty'},'空分组，可将设备移入此处。')
                    ]);
                    folder.open=!!q||state[key]!==false;
                    folder.addEventListener('toggle',function(){if(!q)state[key]=folder.open;});
                    folders.push(folder);return folder;
                });
                return E('section',{'class':'pd-section'},[
                    E('h3',{},section.title+'（'+visible.length+(q?'/'+all.length:'')+'）')
                ].concat(nodes.length?nodes:[E('p',{'class':'pd-empty'},q?'没有匹配的设备。':section.empty||'暂无设备。')]));
            });
            content.replaceChildren.apply(content,sections);
        };
        search.addEventListener('input',render);
        var toggle=function(open){folders.forEach(function(f){f.open=open;});};
        render();
        return E('div',{'class':'pd-browser'},[
            E('div',{'class':'pd-tools'},[search,
                E('button',{'class':'btn','click':function(){toggle(true);}},'全部展开'),
                E('button',{'class':'btn','click':function(){toggle(false);}},'全部折叠')
            ].concat(options.canWrite?[
                E('button',{'class':'btn cbi-button-positive','click':function(){self.changeName(management);}},'新建分组'),
                E('button',{'class':'btn','click':function(){self.manage(management);}},'管理分组'),
                E('button',{'class':'btn cbi-button-action','click':function(){self.move(management);}},'批量移动设备')]:[])),content
        ]);
    }
});
