#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const dir=path.resolve(__dirname,'../deploy/personal-agent/.runtime');fs.mkdirSync(dir,{recursive:true,mode:0o700});
for(const name of ['db-password','jwt-key','backend-password','broker-token','storage-key','dashboard-key','node-cookie']){const target=path.join(dir,name);if(!fs.existsSync(target))fs.writeFileSync(target,crypto.randomBytes(36).toString('base64url'),{flag:'wx',mode:0o644});}
for(const name of ['bot-key','model-key']){const target=path.join(dir,name);if(!fs.existsSync(target))fs.writeFileSync(target,'',{flag:'wx',mode:0o644});}
fs.mkdirSync(path.join(dir,'input'),{recursive:true,mode:0o755});
console.log('Prepared ignored local secrets and directories. Fill bot-key/model-key without echoing values; secrets are readable inside their specific containers; parent directory remains owner-only. No containers started.');
