import {createClient} from '@supabase/supabase-js';
import {URL,KEY,EDGE_JWT} from './config.js';
export const sb=createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
function check(result){if(result.error)throw result.error;return result.data}
export async function register(name,password){const response=await fetch(URL+'/functions/v1/register',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+EDGE_JWT,apikey:KEY},body:JSON.stringify({name,password})});const data=await response.json();if(!response.ok)throw new Error(data.error||data.message||'Регистрация недоступна');return data.number}
export async function login(number,password){return check(await sb.auth.signInWithPassword({email:number+'@companion.invalid',password}))}
export async function profile(id){return check(await sb.from('profiles').select('*').eq('id',id).single())}
export async function find(number){return check(await sb.from('profiles').select('*').eq('number',number).maybeSingle())}
export async function profiles(ids){if(!ids.length)return [];return check(await sb.from('profiles').select('*').in('id',ids))}
export async function messages(){return check(await sb.from('messages').select('*').order('created_at',{ascending:false}).limit(1000)).reverse()}
export async function send(sender,recipient,text){return check(await sb.from('messages').insert({sender,recipient,text}).select().single())}
export async function edit(id,text){return check(await sb.from('messages').update({text,edited:true}).eq('id',id).select().single())}
export async function remove(id){return check(await sb.from('messages').delete().eq('id',id))}
export async function update(id,name,bio){return check(await sb.from('profiles').update({name,bio}).eq('id',id).select().single())}
