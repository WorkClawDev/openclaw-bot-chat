'use strict';
// Loopback-only WebKit/SMS UI fixture. It never contacts Cloudflare or sends SMS.
const {createServer} = require('node:http');
const port = Number(process.env.IOS_PHONE_FIXTURE_PORT || 18086);
let attempts = [], challengeLoads = 0, rejectNext = false, unavailablePage = false;
const page = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:18px system-ui;padding:24px}button{display:block;width:100%;padding:18px;margin:20px 0;font:inherit}</style><h3>Local verification test</h3><button onclick="report('verified','ui-verification-token')">Verify successfully</button><button onclick="report('expired')">Verification expires</button><button onclick="report('error')">Verification fails</button><script>function report(event,token){window.webkit.messageHandlers.phoneCaptcha.postMessage({event,token:token||''})}</script>`;
createServer(async (req,res) => {
 const path = new URL(req.url,'http://localhost').pathname;
 const chunks=[];for await(const chunk of req)chunks.push(chunk);
 let body={};try {if(chunks.length)body=JSON.parse(Buffer.concat(chunks));}catch{res.writeHead(400).end();return;}
 const send=(data,status=200,message='ok')=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'}).end(JSON.stringify({code:status===200?0:status,message,data}));};
 if(path==='/fixture/reset'&&req.method==='POST'){attempts=[];challengeLoads=0;rejectNext=false;unavailablePage=false;send({});return;}
 if(path==='/fixture/mode'&&req.method==='POST'){rejectNext=!!body.reject_next;unavailablePage=!!body.unavailable_page;send({});return;}
 if(path==='/fixture/events'){send({attempts,challenge_loads:challengeLoads});return;}
 if(path==='/api/v1/auth/phone/config'){send({enabled:true,captcha_provider:'turnstile'});return;}
 if(path==='/api/v1/auth/phone/challenge'){
  challengeLoads++;
  if(unavailablePage){send({},503,'Verification temporarily unavailable');return;}
  res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}).end(page);return;
 }
 if(path==='/api/v1/auth/phone/code'&&req.method==='POST'){
  const valid=body.captcha_token==='ui-verification-token'&&body.purpose==='login';
  attempts.push({phone:body.phone,valid_token:valid});
  if(!valid){send({},400,'Invalid verification token');return;}
  if(rejectNext){rejectNext=false;send({},503,'SMS temporarily unavailable');return;}
  send({cooldown_seconds:60});return;
 }
 send({},404,'Unsupported fixture route');
}).listen(port,'127.0.0.1',()=>console.log('Phone verification UI fixture listening on loopback '+port));
