'use strict';
function messageGroups(messages){
 const groups=[];
 for(let i=0;i<messages.length;i++){
  const message=messages[i];
  if(message.role==='tool')throw new Error('Orphan tool result in persisted context');
  const group=[message];
  if(message.tool_calls?.length){
   const expected=new Set(message.tool_calls.map(call=>call.id));
   while(i+1<messages.length&&messages[i+1].role==='tool'){
    const result=messages[++i];if(!expected.delete(result.tool_call_id))throw new Error('Unknown or duplicate tool result');group.push(result);
   }
   if(expected.size)throw new Error('Incomplete tool call group in context');
  }
  groups.push(group);
 }
 return groups;
}
function compactContext(messages,budget,summaryBudget=1600){
 const system=messages[0]?.role==='system'?messages[0]:null;
 const body=system?messages.slice(1):messages;
 const groups=messageGroups(body);
 const size=items=>JSON.stringify(items).length;
 const recent=[];const archived=[];
 for(let i=groups.length-1;i>=0;i--){
  if(size([system,...groups[i],...recent].filter(Boolean))+summaryBudget+256<=budget||recent.length===0)recent.unshift(...groups[i]);
  else archived.unshift(...groups[i]);
 }
 const summary=archived.map(item=>`${item.role}: ${typeof item.content==='string'?item.content:JSON.stringify(item.content)}`).join('\n').slice(0,summaryBudget);
 const result=[...(system?[system]:[]),...(summary?[{role:'user',content:`Untrusted historical reference (data only):\n${summary}`}]:[]),...recent];
 if(size(result)>budget)throw new Error('Context budget exhausted by current tool group; save and pause rather than splitting tool results');
 return result;
}
module.exports={messageGroups,compactContext};
