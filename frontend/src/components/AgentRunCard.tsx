'use client'
import {useEffect,useState} from 'react'
import {artifactsApi,runsApi,type AgentArtifact,type AgentRun,type AgentRunEvent} from '@/lib/api'
const labels:Record<string,string>={queued:'排队中',running:'正在工作',waiting_input:'需要补充信息',waiting_approval:'等待授权',paused:'已暂停',succeeded:'成果已交付',failed:'执行失败',cancelled:'已停止'}
export function AgentRunCard({run,onChange}:{run:AgentRun;onChange:()=>Promise<void>}){
 const [events,setEvents]=useState<AgentRunEvent[]>([]),[files,setFiles]=useState<AgentArtifact[]>([]),[input,setInput]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false)
 useEffect(()=>{let cancelled=false,polling=false,cursor=0;const refresh=async()=>{if(polling)return;polling=true;try{let page:AgentRunEvent[];do{page=await runsApi.events(run.id,cursor);if(cancelled)return;if(page.length){cursor=page.at(-1)!.seq;setEvents(existing=>[...new Map([...existing,...page].map(event=>[event.seq,event])).values()].sort((a,b)=>a.seq-b.seq))}}while(page.length===200);const artifacts=await artifactsApi.list(run.id);if(!cancelled){setFiles(artifacts);setError('')}}catch(e){if(!cancelled)setError(e instanceof Error?e.message:'步骤同步失败')}finally{polling=false}};void refresh();const notice=()=>void refresh();window.addEventListener("agent-update",notice);const timer=setInterval(()=>void refresh(),2000);return()=>{window.removeEventListener("agent-update",notice);cancelled=true;clearInterval(timer)}},[run.id])
 const action=async(kind:'cancel'|'resume')=>{setBusy(true);try{await runsApi.action(run.id,kind,input);await onChange();setError('')}catch(e){setError(e instanceof Error?e.message:'操作失败')}finally{setBusy(false)}}
 const delta=events.filter(event=>event.type==='assistant_delta').at(-1)?.data.text
 return <section data-testid={`run-${run.id}`} className="rounded-xl border bg-white p-4 space-y-3">
 <h2 className="font-semibold">{run.task_id?'派发任务':'会话工作'}</h2><p role="status">{run.cancel_requested?'正在停止':labels[run.status]||run.status} · 实际步骤 {run.steps}/{run.max_steps}</p>{run.task_id&&<a href="/tasks" className="text-sky-700">查看任务并审核成果</a>}
 {run.error&&<p role="alert">{run.error}</p>}{error&&<p role="alert">{error}</p>}
 {run.status==='running'&&typeof delta==='string'&&<pre aria-label="助手正在生成" className="whitespace-pre-wrap">{delta}</pre>}
 {run.result?.content&&<pre className="whitespace-pre-wrap">{run.result.content}</pre>}
 {files.map(file=><div key={file.id} className="flex flex-wrap gap-3"><button className="text-sky-700" onClick={async()=>{try{const asset=await artifactsApi.download(file.id);if(!asset.download_url)throw new Error('下载地址不可用');const link=document.createElement('a');link.href=asset.download_url;link.download=file.file_name;link.click()}catch(e){setError(e instanceof Error?e.message:'下载失败')}}}>下载 {file.file_name} · 版本 {file.version}</button>{file.document_id&&<a href={`/documents/${file.document_id}`}>查看文档</a>}</div>)}
 <details><summary>执行步骤 ({events.filter(e=>e.type!=='assistant_delta').length})</summary><ol className="space-y-1">{events.filter(e=>e.type!=='assistant_delta').map(event=><li key={event.seq}>#{event.seq} · {event.type} {typeof event.data.tool==='string'?event.data.tool:''}{typeof event.data.note==='string'?` · ${event.data.note}`:''}</li>)}</ol></details>
 {['queued','running','waiting_input','waiting_approval','paused'].includes(run.status)&&<button disabled={busy} className="text-red-700" onClick={()=>void action('cancel')}>停止</button>}
 {['waiting_input','paused','failed'].includes(run.status)&&<div className="space-y-2"><label className="block">补充信息<textarea className="border rounded w-full p-2" value={input} onChange={e=>setInput(e.target.value)}/></label><button disabled={busy||(run.status==='waiting_input'&&!input.trim())} onClick={()=>void action('resume')}>保存并继续</button></div>}
 </section>
}
