import {createHash,randomUUID} from 'node:crypto';
import {BotChatHttpClient,BotChatHttpError,type AgentLease} from '../client/http';
import type {OpenClawAgent,OpenClawRequest,OpenClawResponse} from '../types';
export interface AgentRun {id:string;status:string;fence:number;cancel_requested:boolean;input:Record<string,unknown>;steps:number;task_id?:string}
export class RunExecutor {
 readonly workerId=randomUUID();
 private readonly active=new Map<string,AbortController>();
 constructor(private readonly client:BotChatHttpClient,private readonly agent:OpenClawAgent,private readonly workspace:string){}
 stop():void {for(const controller of this.active.values())controller.abort(new Error('Worker stopping'));}
 async create(trigger_key:string,conversation:string,input:Record<string,unknown>,task_id?:string):Promise<AgentRun>{return this.client.agentJournal('POST','/runs',{trigger_key,conversation,input,...(task_id?{task_id}:{})});}
 async execute(run:AgentRun,request:OpenClawRequest,beforeRelease?:(response:OpenClawResponse,lease:AgentLease)=>Promise<Record<string,unknown>>):Promise<OpenClawResponse|null>{
  const memory=await this.client.agentJournal<{revision:number;records:Array<{id:string;content:string;source:string;scope:string}>}>("GET",`/memories?scope=${encodeURIComponent(request.session_id)}`);
  let claimed:AgentRun;
  try{claimed=await this.client.agentJournal('POST',`/runs/${run.id}/claim`,{worker_id:this.workerId});}
  catch(error){if(error instanceof BotChatHttpError&&error.status===409)return null;throw error;}
  const lease={runId:claimed.id,workerId:this.workerId,fence:claimed.fence};
  const controller=new AbortController();this.active.set(run.id,controller);
  const signal=request.signal?AbortSignal.any([request.signal,controller.signal]):controller.signal;
  const heartbeat=setInterval(()=>void this.client.agentJournal<AgentRun>('POST',`/runs/${run.id}/heartbeat`,{worker_id:this.workerId,fence:lease.fence}).then(latest=>{if(latest.cancel_requested)controller.abort(new Error("User cancelled"));}).catch(error=>controller.abort(error)),3000);
  const journal=<T>(method:string,url:string,body?:unknown):Promise<T>=>this.client.agentJournal(method,url,body,lease);
  const scope=createHash('sha256').update(JSON.stringify([this.workspace,request.session_id,memory.revision])).digest('hex');
  const executionScope=createHash('sha256').update(`run:${run.id}:memory:${memory.revision}`).digest('hex');
  Object.assign(request,{signal,memories:memory.records,saveMemory:(content:string)=>journal("POST","/memories",{content,scope:request.session_id,source:`message:${request.metadata.message_id??run.id}`,confirmed:true}),deleteMemory:(id:string)=>journal("DELETE",`/memories/${encodeURIComponent(id)}`),getFile:(id:string)=>journal("GET",`/files/${encodeURIComponent(id)}`),deliverArtifact:(input:Record<string,unknown>)=>journal("POST","/artifacts",input),loadState:()=>journal('GET',`/context/${scope}`),saveState:(state:Record<string,unknown>)=>journal('PUT',`/context/${scope}`,state),loadExecution:()=>journal('GET',`/context/${executionScope}`),saveExecution:(state:Record<string,unknown>)=>journal('PUT',`/context/${executionScope}`,state),beforeTool:(intent:Record<string,unknown>)=>journal('POST','/tool-calls/prepare',intent),afterTool:(intent:Record<string,unknown>)=>journal('POST','/tool-calls/complete',intent),audit:(event:Record<string,unknown>)=>journal('POST',`/runs/${run.id}/events`,{worker_id:this.workerId,fence:lease.fence,type:event.type,data:event})});
  request.metadata.run_id=run.id;request.metadata.supplement=claimed.input.supplement;
  request.authorize=async intent=>{const approval=await this.client.approval({...intent,run_id:run.id},lease);if(approval.status==='pending'){const error=new Error(`操作等待授权：${intent.tool}。请在个人助手页面批准本次参数。`)as Error&{code:string};error.code='APPROVAL_PENDING';throw error;}return{approved:approval.status==='approved',run_id:approval.run_id,parameter_hash:approval.parameter_hash,expires_at:approval.expires_at};};
  let status='succeeded',response:OpenClawResponse;
  try{
   try{response=await this.agent.respond(request);signal.throwIfAborted();}
   catch(error){
    const code=(error as {code?:string}).code;const message=error instanceof Error?error.message:String(error);
    if(signal.aborted){status='cancelled';response={content:'执行已停止；已产生的结果保留，未执行步骤已取消。',metadata:{run_state:status}};}
    else if(code==='APPROVAL_PENDING'||code==='INPUT_REQUIRED'||code==='TOOL_UNCERTAIN'){status=code==='APPROVAL_PENDING'?'waiting_approval':'waiting_input';response={content:message,metadata:{run_state:status}};}
    else if(code==='BUDGET_STOP'){status='queued';response={content:'已保存当前步骤，正在继续下一批工作。',metadata:{run_state:status}};}
    else if(/budget exhausted|context budget/i.test(message)){status='paused';response={content:`已保存当前步骤并暂停：${message}`,metadata:{run_state:status}};}
    else{status='failed';response={content:`执行失败，已保存已有步骤：${message}`,metadata:{run_state:status,error:message}};}
   }
   response.metadata={...response.metadata,run_id:run.id,run_state:status};
   // Check fencing before storing any visible result; all journal writes hold the
   // same run row lock. Lease loss cannot masquerade as user cancellation.
   if(controller.signal.aborted&&!(controller.signal.reason instanceof Error&&['Worker stopping','User cancelled'].includes(controller.signal.reason.message)))throw controller.signal.reason;
   const outbox=await beforeRelease?.(response,lease);
   await journal('POST',`/runs/${run.id}/transition`,{worker_id:this.workerId,fence:lease.fence,status,...(outbox?{outbox}:{}),result:{content:response.content,metadata:response.metadata},note:status==='succeeded'?'结果已提交，等待用户审核':response.content});
   return response;
  }finally{clearInterval(heartbeat);this.active.delete(run.id);}
 }
}
