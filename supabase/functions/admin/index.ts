import {createClient} from 'npm:@supabase/supabase-js@2.89.0';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type','Access-Control-Allow-Methods':'POST,OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const ok=(x:unknown,status=200)=>new Response(JSON.stringify(x),{status,headers});
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return ok({});if(req.method!=='POST')return ok({error:'POST required'},405);
 try{
  const auth=req.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return ok({error:'Войдите в аккаунт'},401);
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:session,error:authError}=await admin.auth.getUser(auth.slice(7));if(authError||!session.user)return ok({error:'Сессия истекла'},401);
  const actor=session.user.id;
  const {data:profile}=await admin.from('profiles').select('id,role,banned').eq('id',actor).single();
  if(!profile||profile.banned||!['creator','admin'].includes(profile.role))return ok({error:'Нет прав администратора'},403);
  if((req.headers.get('Content-Type')||'').startsWith('multipart/form-data')){
   if(Number(req.headers.get('Content-Length')||0)>2300000)return ok({error:'Фото до 2 МБ'},400);
   const form=await req.formData(),target=String(form.get('target')||''),kind=String(form.get('kind')||''),file=form.get('file');
   if(!['avatar','cover'].includes(kind)||!(file instanceof File)||file.size>2097152||file.type!=='image/webp')return ok({error:'Недопустимое фото'},400);
   const {data:p}=await admin.from('profiles').select('role').eq('id',target).single();if(!p||p.role==='creator'||(profile.role==='admin'&&p.role!=='user'))return ok({error:'Нет доступа к этому профилю'},403);
   const bytes=new Uint8Array(await file.arrayBuffer());if(new TextDecoder().decode(bytes.slice(0,4))!=='RIFF'||new TextDecoder().decode(bytes.slice(8,12))!=='WEBP')return ok({error:'Неверный формат фото'},400);
   const path=target+'/'+kind+'.webp';const {error}=await admin.storage.from('profile-media').upload(path,file,{upsert:true,contentType:'image/webp',cacheControl:'60'});if(error)throw error;
   return ok({url:admin.storage.from('profile-media').getPublicUrl(path).data.publicUrl+'?v='+Date.now()});
  }
  const raw=await req.text();if(raw.length>12000)return ok({error:'Слишком большой запрос'},400);const body=JSON.parse(raw);
  if(body.action==='list'){
   const page=Math.max(0,Math.min(100000,Math.floor(Number(body.page)||0)));const query=String(body.query||'').trim().slice(0,60);let q=admin.from('profiles').select('*',{count:'exact'}).order('created_at',{ascending:false}).range(page*30,page*30+29);
   if(query){const safe=query.replace(/[^\p{L}\p{N}_+@ -]/gu,'').replace(/^@/,'');if(safe)q=q.or(`name.ilike.%${safe}%,username.ilike.%${safe}%,number.ilike.%${safe.replace(/\D/g,'')||'no-digits'}%`)}
   const {data,error,count}=await q;if(error)throw error;return ok({users:data,count,page});
  }
  if(body.action==='audit'){const {data,error}=await admin.rpc('admin_audit_log',{actor});if(error)throw error;return ok({events:data})}
  if(body.action!=='update')return ok({error:'Неизвестное действие'},400);
  if(!/^[0-9a-f-]{36}$/i.test(body.target||'')||typeof body.patch!=='object'||body.patch===null||Array.isArray(body.patch))return ok({error:'Некорректные данные'},400);
  const patch=body.patch;
  // Uploaded image paths are limited to this project's public profile bucket.
  for(const field of ['avatar_url','cover_url'])if(field in patch&&patch[field]!==''){
   const u=new URL(patch[field]);if(u.origin!==Deno.env.get('SUPABASE_URL')||!/^\/storage\/v1\/object\/public\/profile-media\/[a-f0-9-]+\/(avatar|cover)\.webp$/.test(u.pathname))return ok({error:'Недопустимый адрес изображения'},400);
  }
  if('number' in patch)patch.number=String(patch.number).replace(/[\s()+-]/g,'');
  if('username' in patch)patch.username=String(patch.username||'').replace(/^@/,'').trim().toLowerCase()||null;
  const request=crypto.randomUUID();const {data:change,error:prepareError}=await admin.rpc('prepare_admin_change',{actor,target:body.target,patch,request});if(prepareError)throw prepareError;
  let authChanged=false;let oldEmail:string|undefined;let oldBan='none';
  try{
   const needsEmail=change.after.number!==change.before.number,needsBan=change.after.banned!==change.before.banned;
   if(needsEmail||needsBan){
    const {data:target,error}=await admin.auth.admin.getUserById(body.target);if(error)throw error;
    oldEmail=target.user.email;const expires=target.user.banned_until?Date.parse(target.user.banned_until):0;oldBan=expires>Date.now()?Math.ceil((expires-Date.now())/3600000)+'h':'none';
    const attrs:Record<string,unknown>={};if(needsEmail){attrs.email=change.after.number+'@companion.invalid';attrs.email_confirm=true}if(needsBan)attrs.ban_duration=change.after.banned?'876000h':'none';
    const {error:updateError}=await admin.auth.admin.updateUserById(body.target,attrs);if(updateError)throw updateError;authChanged=true;
   }
   const {data:saved,error}=await admin.rpc('finish_admin_change',{actor,request});if(error)throw error;return ok({profile:Array.isArray(saved)?saved[0]:saved});
  }catch(e){
   if(authChanged){const {error}=await admin.auth.admin.updateUserById(body.target,{email:oldEmail,email_confirm:true,ban_duration:oldBan});if(error)return ok({error:'Синхронизация аккаунта не завершена. Требуется восстановление операции '+request},500)}
   await admin.rpc('abort_admin_change',{actor,request});throw e;
  }
 }catch(e){const m=e instanceof Error?e.message:(e as {message?:string})?.message||'Ошибка управления аккаунтом';return ok({error:m},400)}
});
