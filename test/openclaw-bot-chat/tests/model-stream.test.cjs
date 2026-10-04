const {test}=require('node:test'),assert=require('node:assert/strict');const {consumeStream}=require('../examples/openai-handler/model-stream.cjs');
function stream(frames,split=3){const raw=Buffer.from(frames.map(frame=>'data: '+(typeof frame==='string'?frame:JSON.stringify(frame))+'\n\n').join(''));return new Response(new ReadableStream({start(controller){for(let i=0;i<raw.length;i+=split)controller.enqueue(raw.subarray(i,i+split));controller.close()}}),{headers:{'content-type':'text/event-stream'}})}
test('stream preserves split UTF-8 and complete tool arguments',async()=>{const deltas=[];const parsed=await consumeStream(stream([{choices:[{delta:{content:'真实'}}]},{choices:[{delta:{tool_calls:[{index:0,id:'tool1',function:{name:'local__file_extract',arguments:'{"path":'}}]}}]},{choices:[{delta:{tool_calls:[{index:0,function:{arguments:'"result.md"}'}}]},finish_reason:'tool_calls'}]},'[DONE]']),{onDelta:async text=>deltas.push(text)});assert.equal(parsed.choices[0].message.content,'真实');assert.equal(parsed.choices[0].message.tool_calls[0].function.arguments,'{"path":"result.md"}');assert.equal(deltas.at(-1),'真实')});
test('truncated stream cannot become a successful result',async()=>{await assert.rejects(consumeStream(stream([{choices:[{delta:{content:'partial'}}]}])),/before completion/)});
test('token-limited stream refuses even syntactically complete tool calls', async () => {
 await assert.rejects(consumeStream(stream([
  {choices:[{delta:{tool_calls:[{index:0,id:'limited',function:{name:'local__fs_write_text',arguments:'{"path":"result.md","content":"partial"}'}}]},finish_reason:'length'}]},
  '[DONE]',
 ])), /before completion.*length/);
});
test('non-streaming responses also refuse token-limited tool execution', () => {
 const {createModelClient} = require('../examples/openai-handler/model-client.cjs');
 const client = createModelClient({isRecord:value => value !== null && typeof value === 'object'});
 assert.throws(() => client.extractAssistantMessage({choices:[{
  finish_reason:'length',message:{role:'assistant',tool_calls:[{id:'limited',type:'function',function:{name:'local__fs_write_text',arguments:'{}'}}]},
 }]}), /before completion.*length/);
});
test('cancellation interrupts stream consumption',async()=>{const controller=new AbortController();controller.abort(new Error('cancelled'));await assert.rejects(consumeStream(stream(['[DONE]']),{signal:controller.signal}),/cancelled/)});

test('provider usage is recorded only when actually supplied',async()=>{const parsed=await consumeStream(stream([{choices:[{delta:{content:'observed'},finish_reason:'stop'}]},{choices:[],usage:{prompt_tokens:4,completion_tokens:2,total_tokens:6}},'[DONE]']));assert.equal(parsed.usage.total_tokens,6);const noUsage=await consumeStream(stream([{choices:[{delta:{content:'plain'},finish_reason:'stop'}]},'[DONE]']));assert.equal(noUsage.usage,undefined);});
