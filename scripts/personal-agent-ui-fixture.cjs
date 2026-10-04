'use strict';
// Isolated UI contract fixture; deliberately does not represent live provider,
// broker or PostgreSQL acceptance. No real credentials are read.
const {createServer}=require('node:http'),{randomUUID}=require('node:crypto');
const port=Number(process.env.PERSONAL_AGENT_UI_PORT||18081),bot='00000000-0000-4000-8000-000000000001',run='00000000-0000-4000-8000-000000000002';
let memory=[],schedules=[],status='waiting_input',approved=false,uncertain=false;
const approval={id:'00000000-0000-4000-8000-000000000003',run_id:run,tool:'local__fs_replace_text',arguments:{path:'/authorized/work/report.md',old_text:'draft',new_text:'reviewed'},parameter_hash:'fixture-hash',status:'pending',expires_at:'2027-01-01T00:00:00Z'};
const server=createServer(async(req,res)=>{res.setHeader('Access-Control-Allow-Origin','http://127.0.0.1:13001');res.setHeader('Access-Control-Allow-Headers','Authorization,Content-Type');res.setHeader('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');if(req.method==='OPTIONS'){res.end();return};const url=new URL(req.url,'http://fixture');const path=url.pathname;let body={};try{const chunks=[];for await(const c of req)chunks.push(c);if(chunks.length)body=JSON.parse(Buffer.concat(chunks));}catch{res.writeHead(400);res.end();return};let data;
 if(path==='/health'){data={status:'fixture'}}
 else if(path==='/fixture/reset'){memory=[];schedules=[];status='waiting_input';approved=false;uncertain=false;data={status:'reset'}}
 else if(path==='/fixture/uncertain'){uncertain=true;status='waiting_input';data={status:'configured'}}
 else if(path==='/api/v1/agent/tool-calls/uncertain'){data=uncertain?[{id:'tool-uncertain',run_id:run,tool:'fixture_external_write'}]:[]}
 else if(path.endsWith('/reconcile')){if(!body.evidence||body.evidence.length<3){res.writeHead(400);res.end();return};uncertain=false;data={status:'recorded'}}
 else if(path==='/api/v1/auth/me'){data={id:'00000000-0000-4000-8000-000000000004',username:'Disposable UI User',nickname:'UI User',status:1,created_at:'2026-10-03T00:00:00Z'}}
 else if(path==='/api/v1/bots'){data=[{id:bot,name:'Fixture Assistant',status:'online'}]}
 else if(path==='/api/v1/agent/runs'){data=[{id:run,status,cancel_requested:false,steps:2,max_steps:80,event_seq:2,conversation:'fixture',result:{content:status==='waiting_input'?'请补充报告的目标读者':status==='cancelled'?'执行已停止':'已收到补充信息'}}]}
 else if(path.endsWith('/events')){data=Number(url.searchParams.get('after_seq')||0)<2?[{id:'event1',seq:1,type:'model_request',data:{model:'fixture'},created_at:'2026-10-03T00:00:00Z'},{id:'event2',seq:2,type:'waiting_input',data:{note:'目标读者'},created_at:'2026-10-03T00:00:01Z'}]:[]}
 else if(path.endsWith('/artifacts')){data=[{id:'artifact1',run_id:run,file_name:'actual-fixture.md',version:1,sha256:'fixture',size:20,mime_type:'text/markdown'}]}
 else if(path.endsWith('/download')){data={id:'asset1',kind:'file',status:'ready',file_name:'actual-fixture.md',mime_type:'text/markdown',size:20,download_url:`http://127.0.0.1:${port}/fixture/result.md`}}
 else if(path==='/fixture/result.md'){res.setHeader('Content-Disposition','attachment; filename="actual-fixture.md"');res.end('# Actual UI fixture\n');return}
 else if(path.endsWith('/resume')&&!path.includes('schedules')){status='queued';data={status:'resume'}}
 else if(path.endsWith('/cancel')&&!path.includes('schedules')){status='cancelled';data={status:'cancelled'}}
 else if(path==='/api/v1/agent/approvals'){data=approved?[]:[approval]}
 else if(path.endsWith('/decision')){approved=true;data={status:body.approved?'approved':'denied'}}
 else if(path==='/api/v1/agent/memories/export'){data=memory}
 else if(path==='/api/v1/agent/memories'&&req.method==='GET'){data=memory}
 else if(path==='/api/v1/agent/memories'&&req.method==='POST'){data={...body,id:randomUUID()};memory.push(data)}
 else if(path.startsWith('/api/v1/agent/memories/')){const id=path.split('/').at(-1);if(req.method==='DELETE'){memory=memory.filter(m=>m.id!==id);data={status:'deleted'}}else{data={...body,id};memory=memory.map(m=>m.id===id?data:m)}}
 else if(path==='/api/v1/agent/schedules'&&req.method==='GET'){data=schedules}
 else if(path==='/api/v1/agent/schedules'&&req.method==='POST'){data={...body,id:randomUUID(),status:'active',next_at:body.next_at||'2026-10-04T01:00:00Z'};schedules.push(data)}
 else if(path.startsWith('/api/v1/agent/schedules/')){const parts=path.split('/'),id=parts.at(-2),action=parts.at(-1);schedules=schedules.map(s=>s.id===id?{...s,status:{pause:'paused',resume:'active',cancel:'cancelled'}[action]}:s);data={status:action}}
 else{res.writeHead(404);res.end(JSON.stringify({message:'Unsupported fixture route'}));return}
 res.setHeader('Content-Type','application/json');res.end(JSON.stringify({code:0,data,message:'ok'}));});
server.listen(port,'127.0.0.1',()=>process.stdout.write(`Personal agent UI fixture ready on ${port}\n`));
for(const sig of ['SIGINT','SIGTERM'])process.on(sig,()=>server.close(()=>process.exit()));
