'use strict';
// Isolated UI fixture for notification state/permission/navigation testing.
// It does not register with Apple or represent real APNs delivery.
const { createServer } = require('node:http');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { randomUUID } = require('node:crypto');
const port = Number(process.env.IOS_PUSH_FIXTURE_PORT || 18085);
// Match AuthManager.uiTestUser used by -uiTestAuthenticated.
const user = '00000000-0000-0000-0000-000000000111';
const bot = '00000000-0000-4000-8000-000000000001';
const conversation = `chat/dm/user/${user}/bot/${bot}`;
const userB = '00000000-0000-0000-0000-000000000222';
const botB = '00000000-0000-4000-8000-000000000003';
const conversationB = `chat/dm/user/${userB}/bot/${botB}`;
const userData = id => ({ id, username: id === userB ? 'notification-b' : 'ui-test', nickname: id === userB ? 'Notification Account B' : 'Test Runner', email: 'ui-test@example.com' });
const mediaIds = {image:'00000000-0000-4000-8000-000000000010', audio:'00000000-0000-4000-8000-000000000011', file:'00000000-0000-4000-8000-000000000012'};
const group = '00000000-0000-4000-8000-000000000002';
const groupConversation = `chat/group/${group}`;
const groupData = { id: group, name: 'Notification Group', owner_id: user, member_count: 2, is_active: true };
let available = false, scenario = 'settings', events = [];
createServer(async (req, res) => {
  const url = new URL(req.url, 'http://fixture');
  const chunks = []; for await (const chunk of req) chunks.push(chunk);
  let body = {}; try { if (chunks.length) body = JSON.parse(Buffer.concat(chunks)); } catch { res.writeHead(400).end(); return; }
  const account = req.headers.authorization === 'Bearer fixture-account-b' ? userB : user;
  const event = type => events.push({ type, account });
  const mediaFiles = {
    '/fixture/photo.png': ['clawchat-ios/clawchat/Assets.xcassets/AppLogo.imageset/lobster_icon.png', 'image/png'],
    '/fixture/voice.wav': ['artifacts/ios-v5-acceptance/preview-files/voice-short.wav', 'audio/wav'],
  };
  if (mediaFiles[url.pathname]) {
    const [path, mime] = mediaFiles[url.pathname];
    event('download-' + (mime === 'image/png' ? 'image' : 'audio'));
    try { res.writeHead(200, {'Content-Type': mime}).end(readFileSync(resolve(__dirname, '../..', path))); }
    catch { res.writeHead(404).end(); }
    return;
  }
  if (url.pathname === '/fixture/note.txt') {
    event('download-file'); res.writeHead(200, {'Content-Type':'text/plain; charset=utf-8'}).end('V5 NOTIFICATION FILE BODY VERIFIED'); return;
  }
  let data;
  if (url.pathname === '/fixture/reset') { available = body.available === true; scenario = body.scenario || 'settings'; events = []; data = {}; }
  else if (url.pathname === '/fixture/ready-for-push') { events.push({ type: 'ready-for-push', id: randomUUID(), recipient: body.recipient === 'b' ? 'b' : 'a', index: String(body.index || ''), media: String(body.media || '') }); data = {}; }
  else if (url.pathname === '/fixture/events') data = events;
  else if (url.pathname === '/api/v1/push/status') { events.push({ type: 'status' }); data = { available }; }
  else if (url.pathname.startsWith('/api/v1/push/devices/')) { events.push({ type: req.method }); data = { registered: req.method === 'PUT' }; }
  else if (url.pathname === '/api/v1/auth/login') { event('login-b'); data = {user:userData(userB), tokens:{access_token:'fixture-account-b',refresh_token:'fixture-refresh-b'}}; }
  else if (url.pathname === '/api/v1/auth/me') data = userData(account);
  else if (url.pathname === '/api/v1/bots') data = [{ id: account === userB ? botB : bot, name: account === userB ? 'Notification Assistant B' : 'Notification Assistant', status: 'online' }];
  else if ([`/api/v1/bots/${bot}`, `/api/v1/bots/${botB}`].includes(url.pathname)) { event('resolve-bot'); data = { id: account === userB ? botB : bot, name: account === userB ? 'Notification Assistant B' : 'Notification Assistant', status: 'online' }; }
  else if (url.pathname === `/api/v1/groups/${group}`) { events.push({ type: 'resolve-group' }); data = groupData; }
  else if (url.pathname === '/api/v1/messages') {
    event('authorize-history');
    if (scenario === 'forbidden') { res.writeHead(403, { 'Content-Type': 'application/json' }).end(JSON.stringify({ code: 403, message: 'Conversation access revoked' })); return; }
    data = [];
  }
  else if ([`/api/v1/messages/${conversation}`, `/api/v1/messages/${conversationB}`, `/api/v1/messages/${groupConversation}`].includes(url.pathname)) {
    event('load-history');
    const isGroup = url.pathname.endsWith(groupConversation);
    data = [{ id: '00000000-0000-4000-8000-000000000009', conversation_id: isGroup ? groupConversation : account === userB ? conversationB : conversation,
      from: { type: 'bot', id: account === userB ? botB : bot }, to: { type: isGroup ? 'group' : 'user', id: isGroup ? group : account },
      content: { type: 'text', body: account === userB ? 'Account B notification history.' : 'Notification history loaded.' }, seq: 1, timestamp: 1800000000000 }];
    if (scenario === 'media') data = ['image','audio','file'].map((kind, index) => ({
      id: mediaIds[kind], conversation_id: conversation, from:{type:'bot',id:bot},to:{type:'user',id:user},seq:index+1,timestamp:1800000000000+index,
      content:{type:kind, body:kind === 'image' ? 'Notification image caption' : '', name:kind === 'file' ? 'notification-note.txt' : kind === 'audio' ? 'notification-voice.wav' : 'notification-photo.png',
        url:`http://127.0.0.1:${port}/fixture/${{image:'photo.png',audio:'voice.wav',file:'note.txt'}[kind]}`, size:kind==='audio'?192044:1024,
        meta:kind==='image'?{width:128,height:128}:kind==='audio'?{duration:6}:{} }
    }));
  }
  else if (url.pathname === '/api/v1/groups') data = [groupData];
  else if (url.pathname === '/api/v1/conversations') data = [];
  else { res.writeHead(404).end(JSON.stringify({ code: 404, message: 'Unsupported fixture route' })); return; }
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({ code: 0, message: 'ok', data }));
}).listen(port, '127.0.0.1', () => process.stdout.write(`iOS push fixture listening on ${port}\n`));
