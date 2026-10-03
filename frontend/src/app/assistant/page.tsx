'use client'
import {useCallback,useEffect,useState} from 'react'
import {AppLayout} from '@/components/AppLayout'
import {AssistantManagement} from '@/components/AssistantManagement'
import {ToolReconciliation} from '@/components/ToolReconciliation'
import {AgentRunCard} from '@/components/AgentRunCard'
import {agentApi,runsApi,type AgentRun,type AgentApproval} from '@/lib/api'
export default function AssistantPage(){
 const [runs,setRuns]=useState<AgentRun[]>([]),[approvals,setApprovals]=useState<AgentApproval[]>([]),[error,setError]=useState(''),[deciding,setDeciding]=useState<string>()
 const reload=useCallback(async()=>{try{const [decisions,executions]=await Promise.all([agentApi.approvals(),runsApi.list()]);setApprovals(decisions);setRuns(executions);setError('')}catch(e){setError(e instanceof Error?e.message:'读取失败')}},[])
 useEffect(()=>{void reload();const notice=()=>void reload();window.addEventListener("agent-update",notice);const timer=setInterval(()=>void reload(),3000);return()=>{window.removeEventListener("agent-update",notice);clearInterval(timer)}},[reload])
 const decide=async(id:string,approved:boolean)=>{setDeciding(id);try{await agentApi.decide(id,approved);await reload()}catch(e){setError(e instanceof Error?e.message:'决定失败')}finally{setDeciding(undefined)}}
 return <AppLayout><main className="max-w-4xl mx-auto p-4 md:p-6 space-y-5 overflow-y-auto"><h1 className="text-2xl font-semibold">个人助手</h1>{error&&<p role="alert">{error}</p>}
 <section aria-label="操作授权" className="space-y-3"><h2 className="text-xl">操作授权</h2><p>授权绑定本次任务、工具和参数，15 分钟后失效。</p>{approvals.filter(item=>item.status==='pending').map(item=><article key={item.id} className="border rounded-xl bg-white p-4 space-y-2"><h3 className="font-semibold">{item.tool}</h3><p>任务：{item.run_id}</p><pre className="whitespace-pre-wrap break-all">{JSON.stringify(item.arguments,null,2)}</pre>{Date.parse(item.expires_at)>Date.now()?<div className="flex gap-4"><button disabled={deciding===item.id} onClick={()=>void decide(item.id,true)}>批准本次操作</button><button disabled={deciding===item.id} onClick={()=>void decide(item.id,false)}>拒绝</button></div>:<p>已过期，需要重新发起操作。</p>}</article>)}</section>
 <ToolReconciliation/><section aria-label="助手工作" className="space-y-3"><h2 className="text-xl">工作与成果</h2>{runs.length===0&&<p>暂无工作。向助手发送消息或在任务页派发工作。</p>}{runs.map(run=><AgentRunCard key={run.id} run={run} onChange={reload}/>)}</section><AssistantManagement/></main></AppLayout>
}
