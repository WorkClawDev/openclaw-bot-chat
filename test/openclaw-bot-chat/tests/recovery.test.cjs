const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {recoverHistory,ExecutionGate}=require('../dist/runtime/execution.js');
const {stableReplyId}=require('../dist/router/message.js');
const {ManagedBotRuntime}=require('../dist/runtime/bot.js');
const {executeTool}=require('../examples/openai-handler/tool-policy.cjs');
const {compactContext,messageGroups}=require('../examples/openai-handler/context.cjs');
test('history consumes 501 offline messages across pages from local cursor',async()=>{const all=Array.from({length:501},(_,i)=>({message_id:String(i),seq:i+1}));const received=[];let pages=0;await recoverHistory(async(after,limit)=>{pages++;return all.filter(item=>item.seq>after).slice(0,limit)},async item=>received.push(item.seq),0,200);assert.equal(pages,3);assert.deepEqual(received,all.map(item=>item.seq));});
test('outgoing reply id remains stable across restart and separates waiting notice',()=>{assert.equal(stableReplyId('bot','message'),stableReplyId('bot','message'));assert.notEqual(stableReplyId('bot','message'),stableReplyId('bot','message','waiting_approval'));});
function runtimeFixture(agent,records,publish){
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'agent-runtime-'));
 const config={botChatBaseUrl:'http://fixture.invalid',stateDir:dir,httpTimeoutMs:1000,reconnectBaseDelayMs:100,reconnectMaxDelayMs:1000,defaultChannelPolicy:'open'};
 const runtime=new ManagedBotRuntime(config,{key:'fixture',id:'bot',accessKey:'fixture-only',enabled:true,groupPolicy:'open'},agent);
 runtime.botId='bot';runtime.ownerId='user';runtime.mqttClient={publish};runtime.httpClient.agentJournal=async(method,url,body)=>{
  if(url.startsWith('/memories'))return{revision:0,records:[]};
  if(url==='/runs')return {id:'run',status:'queued',fence:1,input:{}};
  if(url==='/runs/run/claim')return {id:'run',status:'running',fence:1,input:{}};
  if(url==='/runs/run/transition'){if(body.outbox)Object.assign(records.get(body.outbox.message_id),{status:body.outbox.status,response:body.outbox.response});return{};}
  if(url.startsWith('/runs/run/'))return {};
  if(url==='/inbox'){if(!records.has(body.message_id))records.set(body.message_id,{message:body.message,status:'accepted',delivered:false});return structuredClone(records.get(body.message_id));}
  if(url==='/inbox/pending')return [...records.values()].filter(row=>row.status!=='completed'||!row.delivered);
  const match=url.match(/^\/inbox\/(.+)\/(finish|delivered)$/);if(match){const row=records.get(decodeURIComponent(match[1]));if(match[2]==='finish')Object.assign(row,body);else row.delivered=true;return{};}
  if(url.startsWith('/context/'))return{};throw Error(url);
 };
 return {runtime,close:()=>fs.rmSync(dir,{recursive:true,force:true})};
}
const message={message_id:'source',dialog_id:'bot/bot/user/user',from_type:'user',from_id:'user',to_type:'bot',to_id:'bot',content_type:'text',body:'hello',timestamp:1,seq:1};
test('100 duplicate deliveries create one logical execution',async()=>{const records=new Map();let calls=0,publishes=0;const f=runtimeFixture({respond:async()=>{calls++;return{content:'actual result'}}},records,async()=>{publishes++});try{await Promise.all(Array.from({length:100},()=>f.runtime.handleIncomingMessage(message)));assert.equal(calls,1);assert.equal(publishes,1);assert.equal(records.size,1);}finally{f.close();}});
test('crash after persisted result and before broker publish resumes outbox without model repeat',async()=>{const records=new Map();let calls=0;const agent={respond:async()=>{calls++;return{content:'saved output'}}};const first=runtimeFixture(agent,records,async()=>{throw Error('broker offline')});try{await assert.rejects(first.runtime.handleIncomingMessage(message),/broker offline/);assert.equal(records.get('source').status,'completed');}finally{first.close();}const sent=[];const second=runtimeFixture(agent,records,async(topic,payload)=>sent.push(payload));try{await second.runtime.handleIncomingMessage(message);assert.equal(calls,1);assert.equal(sent.length,1);assert(records.get('source').delivered);}finally{second.close();}});
test('uncertain external side effect does not repeat on crash recovery',async()=>{let effects=0;const def={name:'external',parameters:{type:'object',properties:{}},policy:{capabilities:['network'],idempotent:false}};await assert.rejects(executeTool(def,{},{runId:'one',beforeTool:async()=>({status:'uncertain'})},()=>effects++),/uncertain/);assert.equal(effects,0);const result=await executeTool(def,{},{runId:'one',beforeTool:async()=>({status:'completed',result:{value:'prior evidence'}})},()=>effects++);assert.equal(result,'prior evidence');assert.equal(effects,0);});
test('compression keeps complete tool pairs and historical data out of system role',()=>{const messages=[{role:'system',content:'trusted policy'},...Array.from({length:30},()=>({role:'user',content:'untrusted file instruction '.repeat(30)})),{role:'assistant',tool_calls:[{id:'call',function:{name:'read',arguments:'{}'}}]},{role:'tool',tool_call_id:'call',content:'actual output'},{role:'user',content:'current goal'}];const compact=compactContext(messages,5000,500);assert.doesNotThrow(()=>messageGroups(compact.slice(1)));assert.equal(compact.filter(item=>item.role==='system').length,1);assert.equal(compact.at(-1).content,'current goal');});
test('execution gate caps running work and rejects excess queue after custody',async()=>{const gate=new ExecutionGate(1,1);let release;const first=gate.run(()=>new Promise(resolve=>release=resolve));const second=gate.run(async()=>2);await assert.rejects(gate.run(async()=>3),/queue full/);release(1);assert.equal(await first,1);assert.equal(await second,2);});

test('personal agent rejects non-owner and group messages before durable custody or execution',async()=>{const records=new Map();let calls=0;const f=runtimeFixture({respond:async()=>{calls++;return{content:'never'}}},records,async()=>{});try{await f.runtime.handleIncomingMessage({...message,from_id:'attacker'});await f.runtime.handleIncomingMessage({...message,to_type:'group',to_id:'group'});await f.runtime.handleIncomingMessage({...message,from_type:'bot'});assert.equal(records.size,0);assert.equal(calls,0);}finally{f.close();}});
