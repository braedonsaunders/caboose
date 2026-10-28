/** Durable task admission and delivery protocol. All guest reads are bounded and validated. */
export interface StoredAttachment { path: string; name: string; mimeType?: string; bytes: number }
export interface QueuedReply { id: string; hash: string; prompt: string; attachments: StoredAttachment[] }
export interface DeliveryIntent { id: string; turn: number; replies: string[]; uncertain?: boolean; claimed?: boolean; legacy?: boolean }
export interface DeliveryJournal {
  version: 1
  original?: string
  turns?: number
  startAttachments?: string[]
  queue: QueuedReply[]
  operations: Array<{ id: string; hash: string; turn?: number }>
  intent?: DeliveryIntent
  cancelled?: number
}
export const JOURNAL_LIMIT = 1024 * 1024
export const MAX_OPERATIONS = 2048
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
export const operationId = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 200 && !/[\u0000-\u001f\u007f]/.test(value)
const hash = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value)
const turn = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) > 0 && Number(value) <= 999999
export const emptyJournal = (): DeliveryJournal => ({ version: 1, queue: [], operations: [] })

/** Validate a retained envelope without rebuilding it: publication compares the original bytes. */
export function readPublishedPrompt(text: string, id: string, intent: DeliveryIntent): { text: string } {
  if (Buffer.byteLength(text) > 262144) throw new Error('Published agent prompt exceeds its limit')
  const value = JSON.parse(text)
  const prefix = `/home/caboose/Agents/${id}/attachments/`
  if (!value || value.type !== 'prompt' || value.turn !== intent.turn || value.deliveryId !== intent.id
      || typeof value.text !== 'string' || !value.text.trim() || value.text.length > 32000 || value.text.includes('\0')
      || (value.attachments !== undefined && (!Array.isArray(value.attachments) || value.attachments.length > 4
        || value.attachments.some((file: any) => !file || typeof file.path !== 'string' || file.path.length > 1024
          || !file.path.startsWith(prefix) || file.path.split('/').some((part: string) => part === '..' || part === '.' || /[\u0000-\u001f]/.test(part))
          || typeof file.name !== 'string' || !file.name || file.name.length > 255 || /[\/\u0000-\u001f]/.test(file.name)
          || (file.mimeType !== undefined && (typeof file.mimeType !== 'string' || file.mimeType.length > 255)))))) {
    throw new Error('Invalid original published agent prompt')
  }
  return { text: value.text }
}

export function readJournal(text: string, id: string): DeliveryJournal {
  if (Buffer.byteLength(text) > JOURNAL_LIMIT) throw new Error('Agent delivery journal exceeds its limit')
  const value = JSON.parse(text)
  const fail = (): never => { throw new Error('Invalid agent delivery journal; recovery requires inspection') }
  if (!value || value.version !== 1 || (value.original !== undefined && !hash(value.original))
      || !Array.isArray(value.queue) || value.queue.length > 10 || !Array.isArray(value.operations) || value.operations.length > MAX_OPERATIONS) return fail()
  const operations = value.operations.map((op: any) => {
    if (!operationId(op?.id) || !hash(op.hash) || (op.turn !== undefined && !turn(op.turn))) return fail()
    return { id: op.id, hash: op.hash, ...(op.turn ? { turn: op.turn } : {}) }
  })
  if (new Set(operations.map((op: { id: string }) => op.id)).size !== operations.length) return fail()
  let totalFiles = 0, totalBytes = 0, totalPrompt = 0
  const queue = value.queue.map((reply: any) => {
    if (!operationId(reply?.id) || !hash(reply.hash) || typeof reply.prompt !== 'string' || !reply.prompt.trim()
        || !Array.isArray(reply.attachments)) return fail()
    totalPrompt += reply.prompt.length + 2
    const attachments = reply.attachments.map((file: any) => {
      if (!file || typeof file.path !== 'string' || file.path.length > 1024
          || !file.path.startsWith(`/home/caboose/Agents/${id}/attachments/`) || file.path.split('/').some((part: string) => part === '..' || part === '.' || /[\u0000-\u001f]/.test(part))
          || typeof file.name !== 'string' || !file.name || file.name.length > 255 || /[\/\u0000-\u001f]/.test(file.name)
          || !Number.isSafeInteger(file.bytes) || file.bytes <= 0 || (file.mimeType !== undefined && (typeof file.mimeType !== 'string' || file.mimeType.length > 255))) return fail()
      totalFiles++; totalBytes += file.bytes
      return { path: file.path, name: file.name, bytes: file.bytes, ...(file.mimeType ? { mimeType: file.mimeType } : {}) }
    })
    if (!operations.some((op: { id: string; hash: string }) => op.id === reply.id && op.hash === reply.hash)) return fail()
    return { id: reply.id, hash: reply.hash, prompt: reply.prompt, attachments }
  })
  if (totalPrompt > 32002 || totalFiles > 4 || totalBytes > 10 * 1024 * 1024 || new Set(queue.map((q: QueuedReply) => q.id)).size !== queue.length) return fail()
  let intent: DeliveryIntent | undefined
  if (value.intent !== undefined) {
    const i = value.intent
    if (!i || !UUID.test(i.id) || !turn(i.turn) || !Array.isArray(i.replies) || i.replies.length > 10
        || !i.replies.every((key: unknown) => operationId(key) && operations.some((op: { id: string }) => op.id === key))
        || (i.uncertain !== undefined && typeof i.uncertain !== 'boolean') || (i.claimed !== undefined && typeof i.claimed !== 'boolean') || (i.legacy !== undefined && typeof i.legacy !== 'boolean')) return fail()
    intent = { id: i.id, turn: i.turn, replies: [...i.replies], ...(i.uncertain ? { uncertain: true } : {}), ...(i.claimed ? { claimed: true } : {}), ...(i.legacy ? { legacy: true } : {}) }
  }
  if (value.turns !== undefined && !turn(value.turns)) return fail()
  if (value.cancelled !== undefined && !turn(value.cancelled)) return fail()
  if (value.startAttachments !== undefined && (!Array.isArray(value.startAttachments) || value.startAttachments.length > 4
      || value.startAttachments.some((file: unknown) => typeof file !== 'string' || file.length > 1024 || !file.startsWith(`/home/caboose/Agents/${id}/attachments/`)
        || /[\u0000-\u001f]/.test(file) || file.slice(`/home/caboose/Agents/${id}/attachments/`.length).includes('/') || file.endsWith('/..') || file.endsWith('/.')))) return fail()
  return { version: 1, ...(value.turns ? { turns: value.turns } : {}), ...(value.startAttachments ? { startAttachments: [...value.startAttachments] } : {}), ...(value.original ? { original: value.original } : {}), queue, operations, ...(intent ? { intent } : {}), ...(value.cancelled ? { cancelled: value.cancelled } : {}) }
}

/** fsync both contents and containing directory. An ambiguous error is read back by the caller. */
export const WRITE_JOURNAL = `// caboose delivery journal write
const fs = require('node:fs/promises'); const path = require('node:path');
(async () => {
 const [file, input, ...chunks] = process.argv.slice(1); const text = input === '@base64' ? Buffer.from(chunks.join(''),'base64').toString('utf8') : input; if (Buffer.byteLength(text) > ${JOURNAL_LIMIT}) throw Error('journal too large');
 await fs.mkdir(path.dirname(file), {recursive:true});
 const tmp = file + '.' + require('node:crypto').randomUUID() + '.tmp';
 const handle = await fs.open(tmp, 'wx', 0o600);
 try { await handle.writeFile(text); await handle.sync(); } finally { await handle.close(); }
 await fs.rename(tmp, file);
 const dir = await fs.open(path.dirname(file), 'r'); try { await dir.sync(); } finally { await dir.close(); }
})().catch(e => { console.error(e.message); process.exitCode=1 });`

/** Re-establish durability after a lost write response; readback alone cannot prove fsync. */
export const CONFIRM_JOURNAL = `// caboose confirm journal
const fs=require('node:fs/promises');const path=require('node:path');
(async()=>{
 const [file,hash]=process.argv.slice(1); const h=await fs.open(file,'r');
 try {const b=Buffer.alloc(${JOURNAL_LIMIT + 1});const r=await h.read(b,0,b.length,0);if(r.bytesRead>${JOURNAL_LIMIT}||require('node:crypto').createHash('sha256').update(b.subarray(0,r.bytesRead)).digest('hex')!==hash)throw Error('journal changed');await h.sync()}finally{await h.close()}
 const dir=await fs.open(path.dirname(file),'r');try{await dir.sync()}finally{await dir.close()}
 console.log('confirmed');
})().catch(e=>{console.error(e.message);process.exitCode=1});`

/** Evidence is read together. A missing inbox is explicitly not an acknowledgement. */
export const READ_DELIVERY = `// caboose delivery evidence
const fs = require('node:fs/promises'); const path = require('node:path');
(async () => {
 const [dir, name] = process.argv.slice(1); const present = new Set();
 const read = async (file, max) => { const h = await fs.open(path.join(dir,file),'r').catch(e=>{if(e.code==='ENOENT')return null;throw e}); if(!h)return ''; present.add(file); try { const s=await h.stat(); if(s.size>max)throw Error('delivery evidence too large'); const b=Buffer.alloc(max+1);const r=await h.read(b,0,b.length,0);if(r.bytesRead>max)throw Error('delivery evidence too large');return b.subarray(0,r.bytesRead).toString('utf8'); } finally {await h.close()} };
 const journal=await read('delivery.json',${JOURNAL_LIMIT});
 const receipt=name ? await read('receipts/'+name+'.json',131072) : '';
 const published=name ? await read('deliveries/'+name+'.json',262144) : '';
 const inbox=name ? await read('inbox/'+name+'.prompt.json',262144) : '';
 const h=await fs.open(path.join(dir,'transcript.jsonl'),'r').catch(e=>{if(e.code==='ENOENT')return null;throw e}); let transcript='';
 if(h) {try {const s=await h.stat(); const start=Math.max(0,s.size-2097152); const b=Buffer.alloc(Math.min(s.size,2097152)); const r=await h.read(b,0,b.length,start); transcript=b.subarray(0,r.bytesRead).toString('utf8'); if(start)transcript=transcript.slice(transcript.indexOf('\\n')+1);}finally{await h.close()}}
 let alive=false; const pid=await read('pid',32); if(/^\\d+\\s*$/.test(pid)){try{process.kill(Number(pid),0);alive=true}catch{}}
 const exit=await read('exit-code',32); console.log(JSON.stringify({journal,receipt,receiptExists:present.has('receipts/'+name+'.json'),inbox,published,transcript,alive:alive&&!exit.trim()}));
})().catch(e=>{console.error(e.message);process.exitCode=1});`

/** Publish once. The write-ahead marker distinguishes an unattempted intent from unknown delivery. */
export const PUBLISH_PROMPT = `// caboose publish prompt
const fs=require('node:fs/promises'); const path=require('node:path');
(async()=>{
 const [dir,input,name]=process.argv.slice(1);
 let text=input; if(input.startsWith('@file:')){const file=path.join(dir,input.slice(6));const h=await fs.open(file,'r');try{const b=Buffer.alloc(262145);const r=await h.read(b,0,b.length,0);if(r.bytesRead>262144)throw Error('prompt too large');text=b.subarray(0,r.bytesRead).toString('utf8')}finally{await h.close()}}
 if(Buffer.byteLength(text)>262144)throw Error('prompt too large');
 const atomic=async(file)=>{const tmp=file+'.tmp';const h=await fs.open(tmp,'w',0o600);try{await h.writeFile(text);await h.sync()}finally{await h.close()}await fs.rename(tmp,file);const d=await fs.open(path.dirname(file),'r');try{await d.sync()}finally{await d.close()}};
 await fs.mkdir(path.join(dir,'deliveries'),{recursive:true}); await fs.mkdir(path.join(dir,'inbox'),{recursive:true});
 const parent=await fs.open(dir,'r');try{await parent.sync()}finally{await parent.close()}
 const marker=path.join(dir,'deliveries',name+'.json');
 const h=await fs.open(marker,'r').catch(e=>{if(e.code==='ENOENT')return null;throw e}); let old=null;
 if(h){try{const b=Buffer.alloc(262145);const r=await h.read(b,0,b.length,0);if(r.bytesRead>262144)throw Error('delivery marker too large');old=b.subarray(0,r.bytesRead).toString('utf8')}finally{await h.close()}}
 if(old!==null){if(old!==text)throw Error('delivery conflict');return;}
 await atomic(marker); await atomic(path.join(dir,'inbox',name+'.prompt.json'));
})().catch(e=>{console.error(e.message);process.exitCode=1});`
