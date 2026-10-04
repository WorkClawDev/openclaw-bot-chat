const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');
const {authorizePath,parameterHash,executeTool,runProcess,isolatedShell}=require('../examples/openai-handler/tool-policy.cjs');
const {createLocalToolRuntime}=require('../examples/openai-handler/local-runtime.cjs');
function fixture(){const dir=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'agent-policy-')));fs.mkdirSync(path.join(dir,'allowed'));return{dir,root:path.join(dir,'allowed'),close:()=>fs.rmSync(dir,{recursive:true,force:true})};}
test('empty roots, traversal, links, hidden files and dangling links are denied',()=>{const f=fixture();try{
 const outside=path.join(f.dir,'outside');fs.writeFileSync(outside,'secret');fs.symlinkSync(outside,path.join(f.root,'link'));fs.symlinkSync(path.join(f.dir,'not-created'),path.join(f.root,'dangling'));
 for(const [file,roots]of [[outside,[]],[outside,[f.root]],[path.join(f.root,'link'),[f.root]],[path.join(f.root,'dangling'),[f.root]],[path.join(f.root,'.env'),[f.root]]])assert.throws(()=>authorizePath(file,roots));
 assert.equal(authorizePath(path.join(f.root,'new','out.md'),[f.root]),path.join(f.root,'new','out.md'));
}finally{f.close();}});
test('schema and expired or modified approvals never execute side effects',async()=>{
 let effects=0;const def={name:'external_publish',parameters:{type:'object',properties:{text:{type:'string'}},required:['text']},policy:{capabilities:['network'],approvalRequired:true}};const args={text:'hello'};
 const invoke=()=>{effects++;return'published';};
 await assert.rejects(executeTool(def,{text:3},{},invoke));
 for(const decision of [{approved:true,run_id:'run',parameter_hash:'wrong',expires_at:'2999-01-01'},{approved:true,run_id:'run',parameter_hash:parameterHash(def.name,args),expires_at:'2000-01-01'}])await assert.rejects(executeTool(def,args,{runId:'run',authorize:async()=>decision},invoke));
 assert.equal(effects,0);
 await executeTool(def,args,{runId:'run',authorize:async()=>({approved:true,run_id:'run',parameter_hash:parameterHash(def.name,args),expires_at:'2999-01-01'})},invoke);assert.equal(effects,1);
});
test('local write goes through common schema and authorized roots',async()=>{const f=fixture();try{
 const runtime=createLocalToolRuntime({enabled:true,readRoots:[f.root],writeRoots:[f.root],maxReadBytes:1024,maxWriteBytes:1024,allowHidden:false,maxToolsPerRequest:10,totalBudgetMs:2000,toolTimeoutMs:1000,toolResultMaxChars:4000,maxParallelTools:1,serializeError:e=>({message:e.message}),truncateText:x=>x,debugLog:()=>{}});const r=await runtime.getRuntime();const file=path.join(f.root,'out.md');
 const outputs=await runtime.callToolsRound(r,[{id:'one',function:{name:'local__fs_write_text',arguments:JSON.stringify({path:file,content:'actual output'})}}],runtime.createToolBudget());assert.equal(fs.readFileSync(file,'utf8'),'actual output');assert(!outputs[0].content.includes('failed'));
 const bad=await runtime.callToolsRound(r,[{id:'two',function:{name:'local__fs_write_text',arguments:JSON.stringify({path:file,content:8})}}],runtime.createToolBudget());assert.match(bad[0].content,/Invalid argument type/);assert.equal(fs.readFileSync(file,'utf8'),'actual output');
}finally{f.close();}});
test('cancellation kills process group before delayed writes',async()=>{const f=fixture();try{
 const output=path.join(f.root,'late');const controller=new AbortController();const pending=runProcess(process.execPath,['-e','setTimeout(()=>require("fs").writeFileSync(process.argv[1],"bad"),1000)',output],{signal:controller.signal,timeoutMs:3000});setTimeout(()=>controller.abort(new Error('stop')),50);await assert.rejects(pending,/stop/);await new Promise(r=>setTimeout(r,1100));assert(!fs.existsSync(output));
}finally{f.close();}});
test('shell cannot fall back to host when isolated runner is absent',async()=>{await assert.rejects(isolatedShell('touch /tmp/should-not-exist','/tmp',{}),/Shell disabled/);});
test('disabled shell is absent from model tools and execution registry', async () => {
 const runtime = createLocalToolRuntime({enabled:true,readRoots:[],writeRoots:[],bashEnabled:false,debugLog:()=>{}});
 const tools = await runtime.getRuntime();
 assert(!tools.tools.some(tool => tool.function.name === 'local__bash_exec'));
 assert(!tools.invokers.has('local__bash_exec'));
 assert(!tools.definitions.has('local__bash_exec'));
});
