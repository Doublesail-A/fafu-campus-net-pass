const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(__dirname+'/rootfiles/www/privacy-register/index.html','utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
async function check(physical){
    const elements={};const document={getElementById(id){return elements[id]||(elements[id]={value:'',checked:false,hidden:false,required:false,disabled:true,events:{},addEventListener(k,v){this.events[k]=v;}});}};
    let request;
    const fetch=async(url,options)=>({json:async()=>{
        if(options?.method==='POST'){request=JSON.parse(options.body);return {ok:true,message:'fixture'};}
        return {ok:true,ca_required:false,allowed:false,enabled:true,physical_mac:physical,mac:'12:00:00:00:00:01',ip:'172.31.255.248',token:'fixture'};
    }});
    vm.runInNewContext(script,{document,navigator:{},fetch});await new Promise(setImmediate);
    assert.equal(elements.submit.disabled,false);
    document.getElementById('otp').value='123456';
    elements.form.events.submit({preventDefault(){}});await new Promise(setImmediate);
    assert.deepEqual(Object.keys(request).sort(),['otp','token']);assert.equal(request.otp,'123456');assert.equal(elements.form.hidden,true);
}
(async()=>{await check(false);await check(true);assert(!html.includes('type="checkbox"'));assert(!html.includes('id="ca-link"'));console.log('PASS portal: OTP-only registration for physical/private MAC, no CA/download/checkbox, CSRF token retained.');})().catch(e=>{console.error(e);process.exitCode=1;});
