// Optional coturn REST credentials. Deploy only after configuring TURN_URLS and TURN_SHARED_SECRET.
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type','Cache-Control':'no-store'};
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,'Content-Type':'application/json'}});
 if(req.method!=='GET')return reply({error:'Method not allowed'},405);
 const auth=req.headers.get('Authorization');if(!auth?.startsWith('Bearer '))return reply({error:'Authentication required'},401);
 const userResponse=await fetch(Deno.env.get('SUPABASE_URL')+'/auth/v1/user',{headers:{Authorization:auth,apikey:Deno.env.get('SUPABASE_ANON_KEY')!}});
 if(!userResponse.ok)return reply({error:'Authentication required'},401);
 const user=await userResponse.json(),secret=Deno.env.get('TURN_SHARED_SECRET'),urls=(Deno.env.get('TURN_URLS')||'').split(',').map(s=>s.trim()).filter(Boolean);
 if(!secret||!urls.length)return reply({error:'TURN is not configured'},503);
 const ttl=600,username=Math.floor(Date.now()/1000+ttl)+':'+user.id;
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-1'},false,['sign']);
 const mac=new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(username)));
 const credential=btoa(String.fromCharCode(...mac));
 return reply({iceServers:[{urls,username,credential}],ttl});
});
