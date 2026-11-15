-- Server-enforced administration. Clients never receive service-role credentials.
alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check check(role in ('user','admin','creator'));
alter table public.profiles add column banned boolean not null default false,add column ban_reason text not null default '' check(char_length(ban_reason)<=200);
create function companion_private.active_user() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.profiles where id=auth.uid() and not banned)$$;
revoke all on function companion_private.active_user() from public,anon;
grant execute on function companion_private.active_user() to authenticated;
create function companion_private.assert_active() returns void language plpgsql stable security definer set search_path='' as $$begin if not companion_private.active_user() then raise exception 'Аккаунт заблокирован или недоступен' using errcode='42501';end if;end$$;
revoke all on function companion_private.assert_active() from public,anon;grant execute on function companion_private.assert_active() to authenticated;
-- Restrictive policies also block still-valid JWTs after a ban.
do $$declare t text;begin foreach t in array array['profiles','messages','wallets','gift_catalog','profile_gifts','calls','call_signals','currency_gifts'] loop execute format('create policy "active account required" on public.%I as restrictive for all to authenticated using ((select companion_private.active_user())) with check ((select companion_private.active_user()))',t);end loop;end$$;
create policy "active account media" on storage.objects as restrictive for all to authenticated using(bucket_id not in('chat-media','profile-media') or (select companion_private.active_user())) with check(bucket_id not in('chat-media','profile-media') or (select companion_private.active_user()));
-- Security-definer RPCs need an explicit ban check; RLS alone cannot constrain them.
do $$declare f record;definition text;begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='companion_private' and p.proname in('purchase_gift','send_currency_gift','my_calls','start_call','call_action','send_call_signal') loop
  definition:=pg_get_functiondef(f.oid);definition:=regexp_replace(definition,'\m[Bb][Ee][Gg][Ii][Nn]\M','begin perform companion_private.assert_active();');execute definition;
 end loop;
end$$;
create table companion_private.admin_changes(id uuid primary key,target uuid not null unique references public.profiles(id),actor uuid not null references public.profiles(id),before_profile jsonb not null,patch jsonb not null,created_at timestamptz not null default now());
alter table companion_private.admin_changes enable row level security;
create table companion_private.admin_audit(id bigint generated always as identity primary key,actor uuid not null references public.profiles(id),target uuid not null references public.profiles(id),before_profile jsonb not null,after_profile jsonb not null,created_at timestamptz not null default now());
alter table companion_private.admin_audit enable row level security;
create index admin_audit_target_time on companion_private.admin_audit(target,created_at desc);
create index admin_audit_actor_time on companion_private.admin_audit(actor,created_at desc);
revoke all on companion_private.admin_changes,companion_private.admin_audit from public,anon,authenticated;
create function companion_private.prepare_admin_change(actor uuid,target uuid,patch jsonb,request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.profiles;t public.profiles;merged public.profiles;k text;begin
 select * into a from public.profiles where id=actor and not banned and role in('creator','admin');if not found then raise exception 'Нет прав администратора' using errcode='42501';end if;
 select * into t from public.profiles where id=target for update;if not found then raise exception 'Пользователь не найден';end if;
 if t.role='creator' or (a.role='admin' and t.role<>'user') then raise exception 'Недостаточно прав для этого аккаунта' using errcode='42501';end if;
 if request is null or jsonb_typeof(patch) is distinct from 'object' or patch='{}'::jsonb then raise exception 'Укажите изменения';end if;
 for k in select jsonb_object_keys(patch) loop if k not in('number','name','bio','username','avatar_url','cover_url','accent','birthday','city','status','header_style','banned','ban_reason','role') then raise exception 'Недопустимое поле: %',k;end if;end loop;
 if patch ? 'role' and (a.role<>'creator' or patch->>'role' is null or patch->>'role' not in('user','admin')) then raise exception 'Только создатель назначает администраторов' using errcode='42501';end if;
 select * into merged from jsonb_populate_record(t,patch);
 if merged.number is null or merged.number !~ '^[0-9]{10,15}$' or merged.number='88888888888' then raise exception 'Номер: от 10 до 15 цифр; номер создателя зарезервирован';end if;
 if merged.username='owner' then raise exception '@owner зарезервирован';end if;
 if exists(select 1 from public.profiles p where p.id<>target and (p.number=merged.number or (merged.username is not null and p.username=merged.username))) then raise exception 'Номер или юзернейм уже занят';end if;
 if exists(select 1 from companion_private.admin_changes c where c.target=prepare_admin_change.target or c.patch->>'number'=merged.number) then raise exception 'Изменение аккаунта уже выполняется. Повторите позже';end if;
 insert into companion_private.admin_changes(id,target,actor,before_profile,patch) values(request,target,actor,to_jsonb(t),patch);
 return jsonb_build_object('id',request,'before',to_jsonb(t),'after',to_jsonb(merged));
end$$;
create function companion_private.finish_admin_change(actor uuid,request uuid) returns public.profiles language plpgsql security definer set search_path='' as $$
declare c companion_private.admin_changes;a public.profiles;t public.profiles;v public.profiles;begin
 select * into c from companion_private.admin_changes where id=request and admin_changes.actor=finish_admin_change.actor for update;if not found then raise exception 'Операция не найдена';end if;
 select * into a from public.profiles where id=actor and not banned and role in('creator','admin');if not found then raise exception 'Права администратора отозваны' using errcode='42501';end if;
 select * into t from public.profiles where id=c.target for update;
 if t.role='creator' or (a.role='admin' and (t.role<>'user' or c.patch ? 'role')) then raise exception 'Недостаточно прав' using errcode='42501';end if;
 select * into v from jsonb_populate_record(t,c.patch);
 update public.profiles set number=v.number,name=v.name,bio=v.bio,username=v.username,avatar_url=v.avatar_url,cover_url=v.cover_url,accent=v.accent,birthday=v.birthday,city=v.city,status=v.status,header_style=v.header_style,banned=v.banned,ban_reason=v.ban_reason,role=v.role where id=c.target returning * into v;
 if v.banned then
  update public.calls set status='ended',ended_at=now() where (caller=v.id or callee=v.id) and status in('ringing','accepted');
  delete from public.call_signals where call_id in(select id from public.calls where caller=v.id or callee=v.id);
 end if;
 insert into companion_private.admin_audit(actor,target,before_profile,after_profile) values(actor,c.target,to_jsonb(t),to_jsonb(v));
 delete from companion_private.admin_changes where id=request;return v;
end$$;
create function companion_private.abort_admin_change(actor uuid,request uuid) returns void language sql security definer set search_path='' as $$delete from companion_private.admin_changes where id=request and admin_changes.actor=abort_admin_change.actor$$;
-- Only Edge Function service role can invoke privileged helpers.
revoke all on function companion_private.prepare_admin_change(uuid,uuid,jsonb,uuid),companion_private.finish_admin_change(uuid,uuid),companion_private.abort_admin_change(uuid,uuid) from public,anon,authenticated;
grant execute on function companion_private.prepare_admin_change(uuid,uuid,jsonb,uuid),companion_private.finish_admin_change(uuid,uuid),companion_private.abort_admin_change(uuid,uuid) to service_role;
create function public.prepare_admin_change(actor uuid,target uuid,patch jsonb,request uuid) returns jsonb language sql security invoker set search_path='' as $$select companion_private.prepare_admin_change(actor,target,patch,request)$$;
create function public.finish_admin_change(actor uuid,request uuid) returns public.profiles language sql security invoker set search_path='' as $$select companion_private.finish_admin_change(actor,request)$$;
create function public.abort_admin_change(actor uuid,request uuid) returns void language sql security invoker set search_path='' as $$select companion_private.abort_admin_change(actor,request)$$;
revoke all on function public.prepare_admin_change(uuid,uuid,jsonb,uuid),public.finish_admin_change(uuid,uuid),public.abort_admin_change(uuid,uuid) from public,anon,authenticated;
grant execute on function public.prepare_admin_change(uuid,uuid,jsonb,uuid),public.finish_admin_change(uuid,uuid),public.abort_admin_change(uuid,uuid) to service_role;

create function companion_private.admin_audit_log(actor uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$declare r text;result jsonb;begin
 select role into r from public.profiles where id=actor and not banned and role in('creator','admin');if not found then raise exception 'Нет доступа';end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into result from (select a.id,a.actor,a.target,p.name as target_name,a.before_profile,a.after_profile,a.created_at from companion_private.admin_audit a join public.profiles p on p.id=a.target where r='creator' or a.actor=admin_audit_log.actor order by a.id desc limit 100)x;return result;
end$$;
revoke all on function companion_private.admin_audit_log(uuid) from public,anon,authenticated;grant execute on function companion_private.admin_audit_log(uuid) to service_role;
create function public.admin_audit_log(actor uuid) returns jsonb language sql security invoker set search_path='' as $$select companion_private.admin_audit_log(actor)$$;
revoke all on function public.admin_audit_log(uuid) from public,anon,authenticated;grant execute on function public.admin_audit_log(uuid) to service_role;
create function companion_private.account_status() returns jsonb language sql stable security definer set search_path='' as $$select jsonb_build_object('banned',banned,'ban_reason',ban_reason,'role',role,'number',number) from public.profiles where id=auth.uid()$$;
revoke all on function companion_private.account_status() from public,anon;grant execute on function companion_private.account_status() to authenticated;
create function public.account_status() returns jsonb language sql security invoker set search_path='' as $$select companion_private.account_status()$$;
revoke all on function public.account_status() from public,anon;grant execute on function public.account_status() to authenticated;

create policy "service administration" on companion_private.admin_changes for all to service_role using(true) with check(true);
create policy "service audit" on companion_private.admin_audit for all to service_role using(true) with check(true);
create index admin_changes_actor on companion_private.admin_changes(actor);
