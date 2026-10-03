'use client'
import {useEffect,useState} from 'react'
import {AppLayout} from '@/components/AppLayout'
import {agentApi,type AgentApproval} from '@/lib/api'
export default function AssistantPage(){
 const [items,setItems]=useState<AgentApproval[]>([]);const [error,setError]=useState('');
 const reload=async()=>{try{setItems(await agentApi.approvals());setError('')}catch(e){setError(e instanceof Error?e.message:'读取失败')}};
 useEffect(()=>{void reload();const timer=setInterval(()=>void reload(),5000);return()=>clearInterval(timer)},[]);
 const decide=async(id:string,approved:boolean)=>{try{await agentApi.decide(id,approved);await reload()}catch(e){setError(e instanceof Error?e.message:'决定失败')}};
 return <AppLayout><main className="p-6 space-y-4"><h1 className="text-2xl font-semibold">个人助手</h1><p>操作授权会绑定本次任务和具体参数，15 分钟后失效。</p>{error&&<p role="alert">{error}</p>}{items.length===0&&<p>暂无待处理授权。</p>}{items.map(item=><section key={item.id} className="border rounded p-4 space-y-2"><h2>{item.tool}</h2><p>状态：{item.status} · 任务：{item.run_id}</p><pre className="whitespace-pre-wrap break-all">{JSON.stringify(item.arguments,null,2)}</pre>{item.status==='pending'&&Date.parse(item.expires_at)>Date.now()&&<div className="flex gap-4"><button onClick={()=>void decide(item.id,true)}>批准本次操作</button><button onClick={()=>void decide(item.id,false)}>拒绝</button></div>}</section>)}</main></AppLayout>
}
