import {createClient} from '@supabase/supabase-js';
import {URL,KEY,EDGE_JWT} from './config.js';
export const sb=createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
function check(result){if(result.error)throw result.error;return result.data}
export async function register(name,password,prefix){const response=await fetch(URL+'/functions/v1/register',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+EDGE_JWT,apikey:KEY},body:JSON.stringify({name,password,prefix})});const data=await response.json();if(!response.ok)throw new Error(data.error||data.message||'Регистрация недоступна');return data.number}
export async function login(number,password){const result=await sb.auth.signInWithPassword({email:normalizeNumber(number)+'@companion.invalid',password});if(result.error?.code==='user_banned')throw Error('Аккаунт заблокирован администратором');return check(result)}
export async function profile(id){return check(await sb.from('profiles').select('*').eq('id',id).single())}
export function normalizeNumber(n){const v=String(n).replace(/[\s()+-]/g,'');if(!/^[0-9]{10,15}$/.test(v))throw new Error('Введите номер: от 10 до 15 цифр, можно с +');return v}
export async function find(query){const q=String(query).trim();const field=/[a-zA-Z_@]/.test(q)?'username':'number';const value=field==='username'?q.replace(/^@/,'').toLowerCase():normalizeNumber(q);return check(await sb.from('profiles').select('*').eq(field,value).maybeSingle())}
export async function profiles(ids){if(!ids.length)return [];return check(await sb.from('profiles').select('*').in('id',ids))}
export async function messages(){return check(await sb.from('messages').select('*').order('created_at',{ascending:false}).limit(1000)).reverse()}
export async function send(sender,recipient,text){return check(await sb.from('messages').insert({sender,recipient,text}).select().single())}
export async function edit(id,text){return check(await sb.from('messages').update({text,edited:true}).eq('id',id).select().single())}
export async function remove(id){const removed=check(await sb.from('messages').delete().eq('id',id).select('id,media_path'));for(const m of removed)if(m.media_path)await sb.storage.from('chat-media').remove([m.media_path]);return removed}
export async function update(id,fields){return check(await sb.from('profiles').update(fields).eq('id',id).select().single())}

export async function wallet(){return check(await sb.from('wallets').select('*').single())}
export async function catalog(){return check(await sb.from('gift_catalog').select('*').eq('active',true).order('stars'))}
export async function inventory(id){return check(await sb.from('profile_gifts').select('*').eq('recipient',id).order('created_at',{ascending:false}).limit(100))}
export async function buyGift(item,target,pay_with,message,request){return check(await sb.rpc('purchase_gift',{item,target,pay_with,message,request}))}
export async function showGift(id,hidden){return check(await sb.from('profile_gifts').update({hidden}).eq('id',id).select().single())}
export async function uploadMedia(id,kind,blob){const path=id+'/'+kind+'.webp';check(await sb.storage.from('profile-media').upload(path,blob,{upsert:true,contentType:'image/webp',cacheControl:'60'}));return sb.storage.from('profile-media').getPublicUrl(path).data.publicUrl+'?v='+Date.now()}
export async function changePassword(password){return check(await sb.auth.updateUser({password}))}

const signedMediaCache=new Map();
export async function chatMediaURL(path,force=false){const session=(await sb.auth.getSession()).data.session;const key=(session?.user.id||'')+':'+path;const cached=signedMediaCache.get(key);if(!force&&cached&&cached.expires>Date.now())return cached.url;const data=check(await sb.storage.from('chat-media').createSignedUrl(path,3600));signedMediaCache.set(key,{url:data.signedUrl,expires:Date.now()+3000000});return data.signedUrl}
export async function sendAttachment(sender,recipient,file,kind,caption='',duration=0,waveform=[]){const mime=(file.type||'').split(';')[0];const extensions={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','video/mp4':'mp4','video/webm':'webm','audio/webm':'webm','audio/ogg':'ogg','audio/mp4':'m4a','audio/mpeg':'mp3','audio/wav':'wav'};const ext=extensions[mime];if(!ext)throw new Error('Этот формат пока не поддерживается');if(file.size>25*1024*1024)throw new Error('Максимальный размер файла — 25 МБ');const path=sender+'/'+crypto.randomUUID()+'.'+ext;check(await sb.storage.from('chat-media').upload(path,file,{contentType:mime,upsert:false}));try{return check(await sb.from('messages').insert({sender,recipient,text:caption,kind,media_path:path,media_mime:mime,media_name:(file.name||'Голосовое сообщение').slice(0,180),media_duration_ms:Math.min(1800000,Math.max(0,Math.round(duration))),media_waveform:waveform}).select().single())}catch(e){await sb.storage.from('chat-media').remove([path]);throw e}}
export async function giftReceipts(ids){if(!ids.length)return [];return check(await sb.from('profile_gifts').select('id,gift_id,note,sender,recipient').in('id',ids))}
export async function activeCalls(){return check(await sb.rpc('my_calls'))}
export async function startCall(target,call_mode,device){return check(await sb.rpc('start_call',{target,call_mode,device}))}
export async function callAction(call,device,action){return check(await sb.rpc('call_action',{call,device,action}))}
export async function signalCall(call,device,signal_kind,payload){return check(await sb.rpc('send_call_signal',{call,device,signal_kind,payload}))}
export async function callSignals(id,uid,last){return check(await sb.from('call_signals').select('*').eq('call_id',id).neq('sender',uid).gt('id',last).order('id'))}
export async function transferCurrency(target,currency,amount,note,request){return check(await sb.rpc('send_currency_gift',{target,currency,amount,note,request}))}
export async function accountStatus(){return check(await sb.rpc('account_status'))}
export async function adminAction(payload){const {data}=await sb.auth.getSession();if(!data.session)throw Error('Войдите в аккаунт');const response=await fetch(URL+'/functions/v1/admin',{method:'POST',headers:{Authorization:'Bearer '+data.session.access_token,apikey:KEY,...(payload instanceof FormData?{}:{'Content-Type':'application/json'})},body:payload instanceof FormData?payload:JSON.stringify(payload)});const result=await response.json();if(!response.ok)throw Error(result.error||'Нет доступа к админ-панели');return result}
