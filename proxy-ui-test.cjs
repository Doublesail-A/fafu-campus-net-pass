const fs=require('node:fs');
const assert=require('node:assert/strict');
const source=fs.readFileSync(__dirname+'/rootfiles/www/luci-static/resources/view/network/privacy-proxy-20261102.js','utf8');
let modal;
function E(tag,attrs,children){
    const list=children===undefined?[]:Array.isArray(children)?children:[children];
    for(const child of list)assert(child!==null&&!Array.isArray(child),'LuCI children must be flat and must not contain null');
    return {tag,attrs:attrs||{},children:list,value:attrs?.value||'',addEventListener(){},replaceChildren(...nodes){this.children=nodes;}};
}
const ui={createHandlerFn:(obj,name)=>obj[name].bind(obj),showModal:(title,children)=>{modal={title,children};}};
const view=new Function('view','rpc','E','L','ui','devices',source)(
    {extend:x=>x},{declare:()=>()=>Promise.resolve(true)},E,
    {bind:(fn,obj,...args)=>fn.bind(obj,...args),url:parts=>'/'+parts},ui,require('./devices-ui-test.cjs').load(E,ui));
const fixture={can_write:true,running:true,available_nodes:1,selected:'privacy-auto',auto_node:'香港01',iot_node:'香港01',iot_nodes:['香港01'],nodes:[{tag:'香港01',type:'anytls',delay:150},{tag:'日本01',type:'anytls',delay:200}],
    devices:[
        {mac:'10:00:00:00:00:01',enabled:true,group:'normal',hostname:'desktop',remark:'电脑',proxy_remaining:0},
        {mac:'10:00:00:00:00:02',enabled:true,group:'normal',proxy_active:true,proxy_permanent:true,proxy_mode:'rule',proxy_node:'日本01'},
        {mac:'10:00:00:00:00:03',enabled:true,group:'iot'},
        {mac:'10:00:00:00:00:04',enabled:false,group:'normal'}
    ]};
function flatten(node){return typeof node==='object'&&node?[node,...node.children.flatMap(flatten)]:[node];}
const nodes=flatten(view.build(fixture));
const tables=nodes.filter(n=>n?.tag==='table');
assert.equal(tables.flatMap(t=>t.children).filter(row=>row.attrs.class!=='pd-head').length,4);
assert(tables.every(t=>t.children.every(row=>row.tag==='tr')));
assert.equal(nodes.filter(n=>n==='临时走代理').length,1);
assert.equal(nodes.filter(n=>n==='修改代理设置').length,1);
assert.equal(nodes.filter(n=>n==='立即恢复').length,1);
assert(nodes.includes('电脑')&&nodes.includes('设备名称：desktop'));
assert(nodes.includes('上传本地配置文件'));
assert(nodes.includes('IoT · TCP 重建直连'));
assert(nodes.some(n=>typeof n==='string'&&n.includes('IoT 通过路由器重建 TCP 后直连')));
assert(nodes.some(n=>typeof n==='string'&&n.includes('最后一次选择')));
assert(nodes.some(n=>n?.tag==='input'&&n.attrs.type==='password'&&n.value===''));
const readonly=flatten(view.build({...fixture,can_write:false,insecure_nodes:0}));
assert(!readonly.includes('临时走代理')&&!readonly.includes('立即恢复'));
assert(readonly.some(n=>n?.tag==='button'&&n.children[0]==='上传本地配置文件'&&n.attrs.disabled));
view.upload('');
assert.equal(modal.title,'从本地导入 FlClash / Clash 配置');
assert(modal.children.flatMap(flatten).some(n=>n?.attrs?.type==='file'&&!n.attrs.accept));
assert(modal.children.flatMap(flatten).some(n=>typeof n==='string'&&n.includes('不下载外部 provider')));
view.temporary(fixture.devices[0]);
assert.equal(modal.title,'设备临时代理');
const duration=modal.children.flatMap(flatten).find(n=>n?.tag==='select');
assert.equal(duration.value,'60');
assert.deepEqual(duration.children.map(o=>o.attrs.value),[15,30,60,120,240,1440,0]);
const selects=modal.children.flatMap(flatten).filter(n=>n?.tag==='select');
assert.equal(selects.length,3);
assert.deepEqual(selects[1].children.map(o=>o.attrs.value),['rule','global']);
assert(selects[2].children.some(o=>o.attrs.value==='privacy-auto'));
assert(selects[2].children.some(o=>o.attrs.value==='日本01'));
assert(!selects[2].children.some(o=>o.attrs.value==='privacy-select'));
view.temporary(fixture.devices[1]);
assert.equal(modal.children.flatMap(flatten).find(n=>n?.attrs?.id==='pp-duration').value,'0');
console.log('PASS proxy view: flat real device rows, no null placeholders, separate names/remarks, masked subscription input, readonly guard, duration dialog, and restore actions.');
