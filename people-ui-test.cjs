const assert=require('node:assert/strict');
const {load,E,flatten}=require('./devices-ui-test.cjs');
let modal,calls=[],refreshes=0;
const ui={showModal:(title,nodes)=>modal={title,nodes},hideModal(){modal=null;}};
const devices=load(E,ui);
const data={owners:['空分组','第二组'],devices:[
    {mac:'02:00:00:00:00:01',configured:true,remark:'电脑',hostname:'pc',owner:'旧组'},
    {mac:'02:00:00:00:00:02',configured:true,remark:'手机',hostname:'phone'},
    {mac:'02:00:00:00:00:03',configured:false,remark:'未授权'}]};
const options={data,run:async args=>{calls.push(args);return {ok:true};},refresh:async()=>{refreshes++;}};
const button=name=>flatten(modal.nodes).find(n=>n?.tag==='button'&&n.children[0]===name);
(async()=>{
    devices.changeName(options);flatten(modal.nodes).find(n=>n?.tag==='input').value='新建空组';await button('新建分组').attrs.click();
    assert.deepEqual(calls.pop(),['people-add','新建空组']);
    devices.changeName(options,'旧组');flatten(modal.nodes).find(n=>n?.tag==='input').value='新组';await button('保存新名称').attrs.click();
    assert.deepEqual(calls.pop(),['people-rename','旧组','新组']);
    devices.move(options,data.devices[0],'第二组');assert.equal(modal.title,'移动设备分组');
    assert.equal(flatten(modal.nodes).filter(n=>n?.attrs?.type==='checkbox').length,2,'Unknown devices must not be offered');
    await button('移动到目标分组').attrs.click();assert.deepEqual(calls.pop(),['people-move','第二组','02:00:00:00:00:01']);
    devices.move(options,null,'空分组');button('全选搜索结果').attrs.click();await button('移动到目标分组').attrs.click();
    assert.deepEqual(calls.pop().sort(),['people-move','空分组','02:00:00:00:00:01','02:00:00:00:00:02'].sort());
    devices.manage(options);assert.equal(modal.title,'管理人员分组');button('删除分组').attrs.click();await button('删除分组').attrs.click();
    assert.equal(calls.pop()[0],'people-remove');
    const browser=devices.browser({...options,state:{},canWrite:true,sections:[{title:'设备',devices:data.devices}],headers:['设备'],row:d=>[devices.identity(d)]});
    const nodes=flatten(browser);
    assert(nodes.includes('新建分组')&&nodes.includes('批量移动设备')&&nodes.includes('管理分组'));
    assert(nodes.includes('空分组，可将设备移入此处。'));
    assert.equal(nodes.filter(n=>n==='移动分组').length,2);
    const readonly=flatten(devices.browser({...options,state:{},canWrite:false,sections:[{title:'设备',devices:data.devices}],headers:['设备'],row:d=>[devices.identity(d)]}));
    assert(!readonly.includes('新建分组')&&!readonly.includes('移动分组'));
    assert.equal(refreshes,5);
    console.log('PASS group UI: create/rename/delete, empty folders, single/batch move, unknown-device and readonly guards.');
})().catch(e=>{console.error(e);process.exitCode=1;});
