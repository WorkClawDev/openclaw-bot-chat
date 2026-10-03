'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {extractFile,readAttachment}=require('../examples/openai-handler/files.cjs');
const {PDFDocument,StandardFonts}=require('pdf-lib');
const ExcelJS=require('exceljs');
test('real CSV, XLSX, DOCX and PDF text extraction preserves content',async()=>{
 assert.match((await extractFile(Buffer.from('name,value\nalpha,4'),'text/csv')).text,/alpha\t4/);
 const book=new ExcelJS.Workbook();book.addWorksheet('Actual').addRow(['real',9]);assert.match((await extractFile(await book.xlsx.writeBuffer(),'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')).text,/real\t9/);
 const zip=new (require('jszip'))();zip.file('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>');zip.file('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Actual DOCX body</w:t></w:r></w:p></w:body></w:document>');assert.match((await extractFile(await zip.generateAsync({type:'nodebuffer'}),'application/vnd.openxmlformats-officedocument.wordprocessingml.document')).text,/Actual DOCX/);
 const pdf=await PDFDocument.create();const font=await pdf.embedFont(StandardFonts.Helvetica);pdf.addPage().drawText('Actual PDF body',{font});assert.match((await extractFile(await pdf.save(),'application/pdf')).text,/Actual PDF/);
});
test('scanned PDF, invalid format, oversized input and cancellation fail visibly',async()=>{
 const pdf=await PDFDocument.create();pdf.addPage();await assert.rejects(extractFile(await pdf.save(),'application/pdf'),/OCR/);
 await assert.rejects(extractFile(Buffer.from('fake'),'application/pdf'),/signature/);
 await assert.rejects(extractFile(Buffer.alloc(8*1024*1024+1),'text/plain'),/limit/);
 const ctrl=new AbortController();ctrl.abort(new Error('stopped'));assert.throws(()=>extractFile(Buffer.from('x'),'text/plain',ctrl.signal),/stopped/);
});
test('archive bomb is refused before document parsing',async()=>{
 const zip=new (require('jszip'))();zip.file('word/document.xml','x'.repeat(1024*1024));await assert.rejects(extractFile(await zip.generateAsync({type:'nodebuffer',compression:'DEFLATE'}),'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),/Unsafe/);
});
test('external file URL without authenticated asset cannot be downloaded',async()=>{
 await assert.rejects(readAttachment({type:'file',url:'https://example.com'},{}),/authorized/);
});
test('table output is an actual workbook and delivery needs the real provider',async()=>{
 const fs=require('node:fs'),os=require('node:os'),path=require('node:path');const {fileTools}=require('../examples/openai-handler/files.cjs');const root=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'agent-table-')));try{const tools=fileTools([root],false,[root]);const target=path.join(root,'result.xlsx');const created=await tools.find(t=>t.name==='local__create_table').invoke({path:target,columns:['Item','Count'],rows:[['actual',3]]},new AbortController().signal);assert.equal(created.rows,1);assert.match((await extractFile(fs.readFileSync(target),'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')).text,/actual\t3/);await assert.rejects(tools.find(t=>t.name==='local__deliver_file').invoke({path:target},new AbortController().signal,{}),/provider unavailable/);}finally{fs.rmSync(root,{recursive:true,force:true});}
});

test('authorized backend file bytes are integrity checked without a public storage fetch',async()=>{const bytes=Buffer.from('internal,7');const hash=require('crypto').createHash('sha256').update(bytes).digest('hex');const value=await readAttachment({asset:{id:'stored'}},{getFile:async()=>({size:bytes.length,mime_type:'text/csv',sha256:hash,content_base64:bytes.toString('base64')})});assert.match(value.text,/internal/);await assert.rejects(readAttachment({asset:{id:'stored'}},{getFile:async()=>({size:1,mime_type:'text/csv',sha256:'wrong',content_base64:'eA=='})}),/integrity/);});
