const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { createServer } = require('node:http');
const { once } = require('node:events');
const { CheckpointStore } = require('../dist/runtime/checkpoint.js');
const { SessionManager } = require('../dist/runtime/session.js');

process.env.BOT_CHAT_RUNTIME_DEBUG = 'false';
process.env.OPENAI_COMPAT_FILESYSTEM_ENABLED = 'false';
const handler = require('../examples/openai-compatible-handler.cjs');

test('default CJS handler supports diagnostics and session-specific memory', async () => {
  assert.equal((await handler.respond({session_id:'one', content:'/ping'})).content,'pong');
  await handler.respond({session_id:'one',content:'/memory use Chinese'});
  assert.match((await handler.respond({session_id:'one',content:'/memory'})).content,/use Chinese/);
  assert.doesNotMatch((await handler.respond({session_id:'two',content:'/memory'})).content,/use Chinese/);
  await handler.respond({session_id:'one',content:'/memory clear'});
  assert.doesNotMatch((await handler.respond({session_id:'one',content:'/memory'})).content,/use Chinese/);
});

test('session and checkpoint state survive reopening', async () => {
  const dir=mkdtempSync(path.join(tmpdir(),'personal-agent-baseline-'));
  try {
    const sessions=new SessionManager(path.join(dir,'sessions.json')); await sessions.load();
    const id=await sessions.getOrCreate('dialog');
    const reopened=new SessionManager(path.join(dir,'sessions.json')); await reopened.load();
    assert.equal(reopened.get('dialog'),id);
    const checkpoint=new CheckpointStore(path.join(dir,'checkpoint.json')); await checkpoint.load();
    await checkpoint.update({dialog_id:'dialog',last_seq:9});
    const restored=new CheckpointStore(path.join(dir,'checkpoint.json')); await restored.load();
    assert.equal(restored.get('dialog').last_seq,9);
  } finally {rmSync(dir,{recursive:true,force:true});}
});

test('default handler calls isolated OpenAI compatible HTTP fixture', async () => {
  let payload;
  const server=createServer(async (req,res)=> {
    const parts=[];for await(const chunk of req) parts.push(chunk);
    payload=JSON.parse(Buffer.concat(parts).toString());
    res.setHeader('content-type','application/json');
    res.end(JSON.stringify({choices:[{message:{role:'assistant',content:'fixture response'}}],usage:{total_tokens:12}}));
  });
  server.listen(0,'127.0.0.1');await once(server,'listening');
  process.env.OPENAI_COMPAT_BASE_URL=`http://127.0.0.1:${server.address().port}/v1`;
  process.env.OPENAI_COMPAT_API_KEY='disposable-fixture-only';
  try {
    const response=await handler.respond({session_id:'fixture',content:'hello'});
    assert.equal(response.content,'fixture response');assert.equal(payload.messages.at(-1).content,'hello');
  } finally {await new Promise(resolve=>server.close(resolve));delete process.env.OPENAI_COMPAT_API_KEY;delete process.env.OPENAI_COMPAT_BASE_URL;}
});

test('doctor reports invalid configuration without exposing credentials', async () => {
  const { doctor } = require('../dist/doctor.js');
  const old={url:process.env.BOT_CHAT_BACKEND_URL,key:process.env.BOT_CHAT_BOT_KEY};
  process.env.BOT_CHAT_BACKEND_URL='not-a-url';process.env.BOT_CHAT_BOT_KEY='fixture-secret-never-output';
  try {
    const diagnostics=await doctor(mkdtempSync(path.join(tmpdir(),'personal-agent-doctor-')));
    assert(diagnostics.some(item=>item.component==='backend.url'&&!item.ok));
    assert(!JSON.stringify(diagnostics).includes('fixture-secret-never-output'));
  } finally {
    if(old.url===undefined)delete process.env.BOT_CHAT_BACKEND_URL;else process.env.BOT_CHAT_BACKEND_URL=old.url;
    if(old.key===undefined)delete process.env.BOT_CHAT_BOT_KEY;else process.env.BOT_CHAT_BOT_KEY=old.key;
  }
});
