'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { spawn } = require('node:child_process');

function within(target, root) {
  const relative=path.relative(root,target);
  return relative==='' || (!relative.startsWith(`..${path.sep}`)&&relative!=='..'&&!path.isAbsolute(relative));
}
function authorizePath(rawPath, roots, allowHidden=false) {
  if (!Array.isArray(roots)||!roots.length) throw new Error('No filesystem roots authorized');
  if (typeof rawPath!=='string'||!rawPath||rawPath.includes('\0')) throw new Error('Invalid filesystem path');
  const target=path.resolve(rawPath);
  const root=roots.map(item=>fs.realpathSync(path.resolve(item))).find(item=>within(target,item));
  if(!root) throw new Error('Path is outside allowed roots');
  const relative=path.relative(root,target);
  if(!allowHidden && relative.split(path.sep).some(item=>item.startsWith('.'))) throw new Error('Hidden file policy denied access');
  // Deny links entirely, including dangling links and directory links. A runner mount
  // is still required when untrusted processes can mutate workspace ancestors.
  let current=root;
  for(const part of relative.split(path.sep).filter(Boolean)) {
    current=path.join(current,part);
    try {if(fs.lstatSync(current).isSymbolicLink()) throw new Error('Symbolic links are not authorized');}
    catch(error) {if(error.code!=='ENOENT')throw error;}
  }
  let existing=target;
  while(!fs.existsSync(existing)) existing=path.dirname(existing);
  if(!within(fs.realpathSync(existing),root)) throw new Error('Real path is outside allowed roots');
  return target;
}
function canonical(value) {
  if(Array.isArray(value))return `[${value.map(canonical).join(',')}]`;
  if(value&&typeof value==='object')return `{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
function parameterHash(tool,args) {return createHash('sha256').update(canonical({tool,args})).digest('hex');}
function validateSchema(schema,args) {
  if(!args||typeof args!=='object'||Array.isArray(args))throw new Error('Tool arguments must be an object');
  for(const key of schema.required||[])if(args[key]===undefined)throw new Error(`Missing required argument: ${key}`);
  for(const [key,value]of Object.entries(args)) {
    const field=schema.properties?.[key];
    if(!field) {if(schema.additionalProperties!==true)throw new Error(`Unknown argument: ${key}`);continue;}
    const types=Array.isArray(field.type)?field.type:[field.type];
    const actual=Array.isArray(value)?'array':value===null?'null':typeof value;
    if(field.type&&!types.includes(actual)&&!(types.includes('integer')&&Number.isInteger(value)))throw new Error(`Invalid argument type: ${key}`);
    if(field.enum&&!field.enum.includes(value))throw new Error(`Invalid argument value: ${key}`);
    if(typeof value==='number'&&((field.minimum!==undefined&&value<field.minimum)||(field.maximum!==undefined&&value>field.maximum)))throw new Error(`Argument out of range: ${key}`);
    if(field.type==='object')validateSchema(field,value);
  }
}
async function executeTool(def,args,context,invoke) {
  const signal=context?.signal;
  signal?.throwIfAborted();
  if(!def.policy||!Array.isArray(def.policy.capabilities))throw new Error('Tool has no explicit capability policy');
  validateSchema(def.parameters,args);
  for(const resource of def.policy.paths||[]) {
    if(args[resource.argument]!==undefined)authorizePath(args[resource.argument],resource.roots,resource.allowHidden);
  }
  if(typeof def.policy.approvalRequired === "function" ? def.policy.approvalRequired(args) : def.policy.approvalRequired) {
    if(!context?.authorize)throw new Error('Approval required; no authenticated approval provider configured');
    const decision=await context.authorize({tool:def.name,parameter_hash:parameterHash(def.name,args),run_id:context.runId,arguments:args});
    if(!decision?.approved || decision.parameter_hash!==parameterHash(def.name,args)||decision.run_id!==context.runId||!Number.isFinite(Date.parse(decision.expires_at))||Date.parse(decision.expires_at)<=Date.now())throw new Error('Approval denied, expired, or parameters changed');
  }
  signal?.throwIfAborted();
  await context?.audit?.({type:'tool_intent',tool:def.name,parameter_hash:parameterHash(def.name,args)});
  const intent={run_id:context?.runId,key:parameterHash(def.name,args),tool:def.name,idempotent:typeof def.policy.idempotent === "function" ? def.policy.idempotent(args) : def.policy.idempotent === true};
  const previous=await context?.beforeTool?.(intent);
  if(previous?.status === "completed")return previous.result.value;
  if(previous?.status === "uncertain") {const error=new Error("Previous external operation has an uncertain result; reconcile it before retry");error.code="TOOL_UNCERTAIN";throw error;}
  signal?.throwIfAborted();
  const result=await invoke(args,signal);
  await context?.afterTool?.({...intent,result:{value:result}});
  signal?.throwIfAborted();
  await context?.audit?.({type:'tool_result',tool:def.name,parameter_hash:parameterHash(def.name,args)});
  return result;
}
function runProcess(command,args,options={}) {
  return new Promise((resolve,reject)=> {
    options.signal?.throwIfAborted();
    const child=spawn(command,args,{cwd:options.cwd,env:options.env??{PATH:process.env.PATH,LANG:'C.UTF-8'},detached:process.platform!=='win32',stdio:['ignore','pipe','pipe']});
    let stdout='',stderr='',settled=false,killTimer;
    const stop=()=> {try {process.kill(-child.pid,'SIGTERM');}catch {child.kill('SIGTERM');}killTimer=setTimeout(()=>{try{process.kill(-child.pid,'SIGKILL');}catch{child.kill('SIGKILL');}},300);};
    const abort=()=>stop();
    options.signal?.addEventListener('abort',abort,{once:true});
    const timeout=setTimeout(stop,options.timeoutMs??20000);
    const max=options.maxBytes??262144;
    child.stdout.on('data',chunk=>{stdout+=chunk;if(Buffer.byteLength(stdout)>max)stop();});
    child.stderr.on('data',chunk=>{stderr+=chunk;if(Buffer.byteLength(stderr)>max)stop();});
    const cleanup=()=>{clearTimeout(timeout);clearTimeout(killTimer);options.signal?.removeEventListener('abort',abort);};
    child.once('error',error=>{if(!settled){settled=true;cleanup();reject(error);}});
    child.once('close',(code,signal)=>{if(!settled){settled=true;cleanup();if(options.signal?.aborted)reject(options.signal.reason??new Error('Cancelled'));else if(signal)reject(new Error(`Process terminated: ${signal}`));else resolve({stdout,stderr,exit_code:code});}});
  });
}
async function isolatedShell(command,cwd,options) {
  if(!options.image)throw new Error('Shell disabled: configure OPENAI_COMPAT_RUNNER_IMAGE for an isolated runner');
  if(!/^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$/.test(options.image))throw new Error('Invalid runner image');
  const name=`personal-agent-tool-${randomUUID()}`;
  const args=['run','--name',name,'--rm','--init','--pull=never','--read-only','--network=none','--cap-drop=ALL','--security-opt=no-new-privileges','--pids-limit=64','--memory=256m','--cpus=1','--user=65534:65534','--tmpfs=/tmp:rw,noexec,nosuid,size=32m','--mount',`type=bind,src=${cwd},dst=/workspace`,'--workdir=/workspace',options.image,'sh','-c',command];
  try { return await runProcess('docker',args,{signal:options.signal,timeoutMs:options.timeoutMs,maxBytes:options.maxBytes}); }
  finally { await runProcess('docker',['rm','-f',name],{timeoutMs:3000}).catch(()=>{}); }
}
module.exports={authorizePath,validateSchema,parameterHash,executeTool,runProcess,isolatedShell};
