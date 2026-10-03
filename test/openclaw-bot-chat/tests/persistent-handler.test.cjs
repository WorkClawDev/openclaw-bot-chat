const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const {createServer}=require('node:http');const {once}=require('node:events');
function reload(){const file=require.resolve('../examples/openai-compatible-handler.cjs');delete require.cache[file];return require(file);}
process.env.BOT_CHAT_RUNTIME_DEBUG='false';
test('restarting handler preserves approved memory and resumes exact pending tool without repeating model planning',async()=>{
 const dir=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'agent-handler-persist-')));const output=path.join(dir,'output.md');fs.writeFileSync(output,'old');
 process.env.OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS=dir;process.env.OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS=dir;process.env.OPENAI_COMPAT_FILESYSTEM_ENABLED='true';
 let calls=0;const server=createServer(async(req,res)=>{const chunks=[];for await(const chunk of req)chunks.push(chunk);const payload=JSON.parse(Buffer.concat(chunks));calls++;res.setHeader('content-type','application/json');res.end(JSON.stringify({choices:[{message:calls===1?{role:'assistant',tool_calls:[{id:'persisted-call',function:{name:'local__fs_write_text',arguments:JSON.stringify({path:output,content:'real artifact'})}}]}:{role:'assistant',content:'delivered actual artifact'}}]}));});server.listen(0,'127.0.0.1');await once(server,'listening');
 process.env.OPENAI_COMPAT_BASE_URL=`http://127.0.0.1:${server.address().port}/v1`;process.env.OPENAI_COMPAT_API_KEY='fixture-only';
 let state={},execution={},approved=false;const tools=new Map();
 const persistence={loadState:async()=>structuredClone(state),saveState:async value=>state=structuredClone(value),loadExecution:async()=>structuredClone(execution),saveExecution:async value=>execution=structuredClone(value),beforeTool:async intent=>{const prior=tools.get(intent.key);if(prior)return prior;const row={status:'started'};tools.set(intent.key,row);return row},afterTool:async intent=>tools.set(intent.key,{status:'completed',result:intent.result})};
 try{
  let handler=reload();await handler.respond({session_id:'conversation',content:'/memory Chinese',metadata:{},...persistence});
  handler=reload();assert.match((await handler.respond({session_id:'conversation',content:'/memory',metadata:{},...persistence})).content,/Chinese/);
  const request={session_id:'conversation',content:'edit file',metadata:{run_id:'run',message_id:'message'},...persistence,authorize:async intent=>{if(!approved){const error=new Error('pending');error.code='APPROVAL_PENDING';throw error;}return{approved:true,run_id:'run',parameter_hash:intent.parameter_hash,expires_at:'2999-01-01'}}};
  await assert.rejects(handler.respond(request),/pending/);assert.equal(fs.readFileSync(output,'utf8'),'old');assert.equal(calls,1);
  approved=true;handler=reload();const result=await handler.respond(request);assert.equal(result.content,'delivered actual artifact');assert.equal(fs.readFileSync(output,'utf8'),'real artifact');assert.equal(calls,2);
  await handler.respond(request);assert.equal(calls,2);assert.equal(state.history.length,2);
 }finally{await new Promise(resolve=>server.close(resolve));fs.rmSync(dir,{recursive:true,force:true});for(const key of ['OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS','OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS','OPENAI_COMPAT_BASE_URL','OPENAI_COMPAT_API_KEY'])delete process.env[key];}
});
test('confirmed memory commands use durable provider and delete derived history',async()=>{
 let state={history:[{role:'user',content:'old summary'}],memory:['old memo']},records=[{id:'m1',content:'confirmed fact',source:'user',scope:'personal'}],saved;
 const request={session_id:'memory-provider',metadata:{},loadState:async()=>state,saveState:async value=>state=value,memories:records,saveMemory:async content=>saved=content,deleteMemory:async id=>records=records.filter(row=>row.id!==id)};
 let handler=reload();assert.match((await handler.respond({...request,content:'/memory'})).content,/confirmed fact/);
 await handler.respond({...request,content:'/memory New confirmed value'});assert.equal(saved,'New confirmed value');
 await handler.respond({...request,content:'/memory delete m1'});assert.equal(records.length,0);assert.deepEqual(state,{history:[],memory:[]});
 handler=reload();assert.equal((await handler.respond({...request,memories:records,content:'/memory'})).content,'暂无已确认记忆。');
});
