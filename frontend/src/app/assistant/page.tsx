'use client'
import {useEffect,useState} from 'react'
import {AppLayout} from '@/components/AppLayout'
import {agentApi,runsApi,type AgentRun,type AgentApproval} from '@/lib/api'
export default function AssistantPage(){
 const [runs,setRuns]=useState<AgentRun[]>([]);const [inputs,setInputs]=useState<Record<string,string>>({});
 const [items,setItems]=useState<AgentApproval[]>([]);const [error,setError]=useState('');
 const reload=async()=>{try{const [approvals,executions]=await Promise.all([agentApi.approvals(),runsApi.list()]);setItems(approvals);setRuns(executions);setError('')}catch(e){setError(e instanceof Error?e.message:'读取失败')}};
 useEffect(()=>{void reload();const timer=setInterval(()=>void reload(),5000);return()=>clearInterval(timer)},[]);
 const decide=async(id:string,approved:boolean)=>{try{await agentApi.decide(id,approved);await reload()}catch(e){setError(e instanceof Error?e.message:'决定失败')}};
 const action=async(id:string,kind:"cancel"|"resume")=>{try{await runsApi.action(id,kind,inputs[id]||"");await reload()}catch(e){setError(e instanceof Error?e.message:"操作失败")}};
 return <AppLayout><main className="p-6 space-y-4"><h1 className="text-2xl font-semibold">个人助手</h1><p>操作授权会绑定本次任务和具体参数，15 分钟后失效。</p>{error&&<p role="alert">{error}</p>}{runs.map(run=><section key={run.id} className="border rounded p-4 space-y-2"><h2>{run.task_id ? `任务 ${run.task_id}` : '会话工作'}</h2><p>状态：{run.cancel_requested ? '正在停止' : run.status} · 实际执行步骤 {run.steps}/{run.max_steps}</p>{run.error&&<p>{run.error}</p>}{run.result?.content&&<pre className="whitespace-pre-wrap">{run.result.content}</pre>}{['queued','running','waiting_input','waiting_approval','paused'].includes(run.status)&&<button onClick={()=>void action(run.id,'cancel')}>停止</button>}{['waiting_input','paused','failed'].includes(run.status)&&<div><label>补充信息<input className="border ml-2" value={inputs[run.id]||''} onChange={e=>setInputs({...inputs,[run.id]:e.target.value})}/></label><button onClick={()=>void action(run.id,'resume')}>保存并继续</button></div>}</section>)}{items.length===0&&<p>暂无待处理授权。</p>}{items.map(item=><section key={item.id} className="border rounded p-4 space-y-2"><h2>{item.tool}</h2><p>状态：{item.status} · 任务：{item.run_id}</p><pre className="whitespace-pre-wrap break-all">{JSON.stringify(item.arguments,null,2)}</pre>{item.status==='pending'&&Date.parse(item.expires_at)>Date.now()&&<div className="flex gap-4"><button onClick={()=>void decide(item.id,true)}>批准本次操作</button><button onClick={()=>void decide(item.id,false)}>拒绝</button></div>}</section>)}</main></AppLayout>
}
