import {createClient} from '@supabase/supabase-js';
import {URL,KEY,EDGE_JWT} from './config.js';
export const sb=createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
function check(result){if(result.error)throw result.error;return result.data}
export async function register(name,password,prefix){const response=await fetch(URL+'/functions/v1/register',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+EDGE_JWT,apikey:KEY},body:JSON.stringify({name,password,prefix})});const data=await response.json();if(!response.ok)throw new Error(data.error||data.message||'Регистрация недоступна');return data.number}
export async function login(number,password){return check(await sb.auth.signInWithPassword({email:normalizeNumber(number)+'@companion.invalid',password}))}
export async function profile(id){return check(await sb.from('profiles').select('*').eq('id',id).single())}
export function normalizeNumber(n){const v=String(n).replace(/[\s()+-]/g,'');if(!/^[0-9]{10,15}$/.test(v))throw new Error('Введите номер: от 10 до 15 цифр, можно с +');return v}
export async function find(query){const q=String(query).trim();const field=/[a-zA-Z_@]/.test(q)?'username':'number';const value=field==='username'?q.replace(/^@/,'').toLowerCase():normalizeNumber(q);return check(await sb.from('profiles').select('*').eq(field,value).maybeSingle())}
export async function profiles(ids){if(!ids.length)return [];return check(await sb.from('profiles').select('*').in('id',ids))}
export async function messages(){return check(await sb.from('messages').select('*').order('created_at',{ascending:false}).limit(1000)).reverse()}
export async function send(sender,recipient,text){return check(await sb.from('messages').insert({sender,recipient,text}).select().single())}
export async function edit(id,text){return check(await sb.from('messages').update({text,edited:true}).eq('id',id).select().single())}
export async function remove(id){return check(await sb.from('messages').delete().eq('id',id))}
export async function update(id,fields){return check(await sb.from('profiles').update(fields).eq('id',id).select().single())}

export async function wallet(){return check(await sb.from('wallets').select('*').single())}
export async function catalog(){return check(await sb.from('gift_catalog').select('*').eq('active',true).order('stars'))}
export async function inventory(id){return check(await sb.from('profile_gifts').select('*').eq('recipient',id).order('created_at',{ascending:false}).limit(100))}
export async function buyGift(item,target,pay_with,message,request){return check(await sb.rpc('purchase_gift',{item,target,pay_with,message,request}))}
export async function showGift(id,hidden){return check(await sb.from('profile_gifts').update({hidden}).eq('id',id).select().single())}
export async function uploadMedia(id,kind,blob){const path=id+'/'+kind+'.webp';check(await sb.storage.from('profile-media').upload(path,blob,{upsert:true,contentType:'image/webp',cacheControl:'60'}));return sb.storage.from('profile-media').getPublicUrl(path).data.publicUrl+'?v='+Date.now()}
export async function changePassword(password){return check(await sb.auth.updateUser({password}))}
