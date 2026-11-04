const fs=require('node:fs'),assert=require('node:assert/strict');
function E(tag,attrs,children){return {tag,attrs:attrs||{},children:children===undefined?[]:Array.isArray(children)?children:[children],value:attrs?.value||'',listeners:{},
    addEventListener(name,fn){this.listeners[name]=fn;},replaceChildren(...nodes){this.children=nodes;}};}
function flatten(n){return Array.isArray(n)?n.flatMap(flatten):n&&typeof n==='object'?[n,...flatten(n.children||[])]:[n];}
function load(Elem=E,ui={}){return new Function('baseclass','E','ui',fs.readFileSync(__dirname+'/rootfiles/www/luci-static/resources/privacy-devices-20261021b.js','utf8'))({extend:v=>v},Elem,ui);}
module.exports={load,E,flatten};
if(require.main===module){
    const devices=load(),state={},data=[
        {mac:'02:00:00:00:00:01',remark:'甲的电脑',hostname:'zzz',owner:'甲',connected:true},
        {mac:'02:00:00:00:00:02',remark:'甲的手机',hostname:'aaa',owner:'甲'},
        {mac:'02:00:00:00:00:03',hostname:'<img src=x>',owner:'__proto__'},
        {mac:'02:00:00:00:00:04',hostname:'未备注'}];
    const browser=devices.browser({state,headers:['设备'],row:d=>[devices.identity(d)],sections:[{title:'全部',devices:data}]});
    let nodes=flatten(browser),folders=nodes.filter(n=>n?.tag==='details');
    assert.equal(folders.length,3);assert(folders.every(n=>n.open));
    assert(nodes.includes('甲')&&nodes.includes('__proto__')&&nodes.includes('未分组'));
    assert(nodes.some(n=>n?.tag==='strong'&&n.children[0]==='甲的电脑'));
    assert(nodes.includes('设备名称：zzz'));
    assert(devices.compare(data[0],data[1])<0); // remark, not hostname
    folders[0].open=false;folders[0].listeners.toggle();
    const search=nodes.find(n=>n?.attrs?.type==='search');search.value='甲';search.listeners.input();
    nodes=flatten(browser);assert.equal(nodes.filter(n=>n?.tag==='details').length,1);
    assert(nodes.find(n=>n?.tag==='details').open);assert(!nodes.includes('未分组'));
    search.value='';search.listeners.input();assert.equal(flatten(browser).find(n=>n?.tag==='details').open,false);
    assert(devices.matches(data[2],'__proto__'));assert(devices.matches(data[0],'zzz'));
    assert(devices.style().children[0].includes('@media(max-width:760px)'));
    console.log('PASS people folders: remark-first, search, escaped text nodes, prototype-safe owners, fold state, mobile cards.');
}
