import { createClient } from "npm:@supabase/supabase-js@2.89.0";
const baseHeaders={"Access-Control-Allow-Origin":"https://ipoteca22848.github.io","Access-Control-Allow-Headers":"authorization,apikey,content-type,x-client-info","Access-Control-Allow-Methods":"POST,OPTIONS","Content-Type":"application/json"};
Deno.serve(async(req)=>{
 const allowed=["https://ipoteca22848.github.io","http://127.0.0.1:8765","http://localhost:8765","http://127.0.0.1:4173","http://localhost:4173"];
 const origin=req.headers.get("origin")||"";
 const headers={...baseHeaders,"Access-Control-Allow-Origin":allowed.includes(origin)?origin:allowed[0],"Vary":"Origin"};
 if(req.method==="OPTIONS")return new Response("ok",{headers});
 if(req.method!=="POST")return new Response(JSON.stringify({error:"POST required"}),{status:405,headers});
 try {
  if(Number(req.headers.get("content-length")||0)>4096)throw new Error("Слишком большой запрос");
  const raw=await req.text();if(raw.length>4096)throw new Error("Слишком большой запрос");
  const {name,password}=JSON.parse(raw);
  if(typeof name!=="string"||name.trim().length<1||name.length>50||typeof password!=="string"||password.length<10||password.length>128)throw new Error("Укажите имя и пароль от 10 до 128 символов");
  const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
  const ip=req.headers.get("x-forwarded-for")?.split(",")[0]?.trim()||req.headers.get("x-real-ip")||"unknown";
  const digest=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(ip+Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")));
  const ipHash=Array.from(new Uint8Array(digest)).map(x=>x.toString(16).padStart(2,"0")).join("");
  const limit=await admin.rpc("consume_signup",{ip:ipHash});
  if(limit.error)throw new Error("Регистрация временно недоступна");
  if(!limit.data)return new Response(JSON.stringify({error:"Можно создать до 5 аккаунтов в час. Попробуйте позже."}),{status:429,headers});
  for(let i=0;i<3;i++){
   const number=String(1000000000+crypto.getRandomValues(new Uint32Array(1))[0]%4000000000);
   const result=await admin.auth.admin.createUser({email:number+"@companion.invalid",password,email_confirm:true,user_metadata:{name:name.trim()}});
   if(!result.error)return new Response(JSON.stringify({number}),{headers});
   if(!result.error.message.toLowerCase().includes("already"))throw new Error("Не удалось создать аккаунт. Попробуйте другой пароль.");
  }
  throw new Error("Повторите попытку");
 }catch(e){return new Response(JSON.stringify({error:e instanceof Error?e.message:"Ошибка регистрации"}),{status:400,headers})}
});
