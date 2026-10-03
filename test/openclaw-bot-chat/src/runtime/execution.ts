import type {BotChatMessage} from '../types';
export async function recoverHistory(fetchPage:(after:number,limit:number)=>Promise<BotChatMessage[]>,consume:(message:BotChatMessage)=>Promise<void>,after=0,limit=200):Promise<void>{
 for(let page=0;page<10000;page++){
  const messages=(await fetchPage(after,limit)).filter(message=>(message.seq??0)>after).sort((a,b)=>(a.seq??0)-(b.seq??0));
  if(!messages.length)return;
  for(const message of messages)await consume(message);
  const next=Math.max(...messages.map(message=>message.seq??0));
  if(next<=after)throw new Error('History pagination did not advance');
  after=next;if(messages.length<limit)return;
 }
 throw new Error('History pagination exceeded safety limit');
}
export class ExecutionGate {
 private active=0;private readonly waiting:Array<()=>void>=[];
 constructor(private readonly limit=4,private readonly capacity=200){}
 async run<T>(execute:()=>Promise<T>):Promise<T>{
  if(this.active>=this.limit){if(this.waiting.length>=this.capacity)throw new Error('Execution queue full; durable inbox will retry');await new Promise<void>(resolve=>this.waiting.push(resolve));}
  else this.active++;
  try{return await execute();}finally{const next=this.waiting.shift();if(next)next();else this.active--;}
 }
}
