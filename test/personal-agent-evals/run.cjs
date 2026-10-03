#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'../..'),cases=require('./scenarios.json'),results=[];const dir=path.join(__dirname,'results');fs.mkdirSync(dir,{recursive:true,mode:0o700});
const run=(command,args)=>{const r=spawnSync(command,args,{cwd:root,env:{...process.env,GOCACHE:process.env.GOCACHE||'/tmp/personal-agent-gocache'},encoding:'utf8',maxBuffer:32*1024*1024});if(r.error)throw r.error;return r};
const build=run('npm',['--prefix','test/openclaw-bot-chat','run','build']);
const files=fs.readdirSync(path.join(root,'test/openclaw-bot-chat/tests')).filter(f=>f.endsWith('.test.cjs')).map(f=>'test/openclaw-bot-chat/tests/'+f);
const node=build.status===0?run(process.execPath,['--test','--test-reporter=tap',...files]):build;
const go=run('go',['-C','backend','test','-json','./...']);
fs.writeFileSync(path.join(dir,'node.log'),node.stdout+node.stderr,{mode:0o600});fs.writeFileSync(path.join(dir,'go.jsonl'),go.stdout+go.stderr,{mode:0o600});
const nodePass=new Set([...node.stdout.matchAll(/^ok \d+ - (.+)$/gm)].map(m=>m[1]));const goEvents=[];for(const line of go.stdout.split('\n')){try{goEvents.push(JSON.parse(line))}catch{}}
for(const item of cases){const passed=item.engine==='node'?nodePass.has(item.test):goEvents.some(e=>e.Action==='pass'&&e.Package===item.package&&e.Test===item.test);const failed=item.engine==='node'?new RegExp('^not ok \\d+ - '+item.test.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$','m').test(node.stdout):goEvents.some(e=>e.Action==='fail'&&e.Package===item.package&&e.Test===item.test);results.push({id:item.id,scenario:item.scenario,deterministic:passed?'passed':failed?'failed':'not_run',real_service:'not_run',evidence:item.engine==='node'?'node.log':'go.jsonl'})}
const report={at:new Date().toISOString(),type:'deterministic-behavior-regression',node_exit:node.status,go_exit:go.status,counts:{passed:results.filter(x=>x.deterministic==='passed').length,failed:results.filter(x=>x.deterministic==='failed').length,not_run:results.filter(x=>x.deterministic==='not_run').length,real_service_not_run:40},results};fs.writeFileSync(path.join(dir,'latest.json'),JSON.stringify(report,null,2),{mode:0o600});console.log(JSON.stringify(report.counts));process.exitCode=report.counts.passed===40&&node.status===0&&go.status===0?0:1;
