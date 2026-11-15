-- WebRTC signaling metadata only; no call audio/video is stored in the database.
create table public.calls(
 id uuid primary key default gen_random_uuid(),caller uuid not null references public.profiles(id),callee uuid not null references public.profiles(id),mode text not null check(mode in ('audio','video')),
 status text not null default 'ringing' check(status in ('ringing','accepted','ended','declined','missed','failed')),
 caller_device uuid not null,callee_device uuid,created_at timestamptz not null default now(),answered_at timestamptz,ended_at timestamptz,caller_seen_at timestamptz not null default now(),callee_seen_at timestamptz not null default now(),check(caller<>callee)
);
alter table public.calls enable row level security;
revoke all on public.calls from anon,authenticated;grant select on public.calls to authenticated;
create policy "call participants" on public.calls for select to authenticated using(caller=(select auth.uid()) or callee=(select auth.uid()));
create index calls_caller_recent on public.calls(caller,created_at desc);
create index calls_callee_active on public.calls(callee,status,created_at desc);
create table public.call_signals(id bigint generated always as identity primary key,call_id uuid not null references public.calls(id) on delete cascade,sender uuid not null references public.profiles(id),kind text not null check(kind in ('offer','answer','ice','control')),data jsonb not null check(octet_length(data::text)<=65536),created_at timestamptz not null default now());
alter table public.call_signals enable row level security;
revoke all on public.call_signals from anon,authenticated;grant select on public.call_signals to authenticated;
create policy "signals participants" on public.call_signals for select to authenticated using(exists(select 1 from public.calls c where c.id=call_id and (c.caller=(select auth.uid()) or c.callee=(select auth.uid()))));
create index call_signals_call_seq on public.call_signals(call_id,id);
create index call_signals_sender on public.call_signals(sender);
create unique index call_one_offer on public.call_signals(call_id) where kind='offer';
create unique index call_one_answer on public.call_signals(call_id) where kind='answer';
create function companion_private.my_calls() returns setof public.calls language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();begin
 if uid is null then raise exception 'Войдите в аккаунт';end if;
 update public.calls set status=case when status='ringing' then 'missed' else 'failed' end,ended_at=now() where (caller=uid or callee=uid) and ((status='ringing' and created_at<now()-interval '60 seconds') or (status='accepted' and least(caller_seen_at,callee_seen_at)<now()-interval '45 seconds'));
 delete from public.call_signals s using public.calls c where s.call_id=c.id and c.status not in ('ringing','accepted') and (c.caller=uid or c.callee=uid);
 return query select c.* from public.calls c where (c.caller=uid or c.callee=uid) and c.status in ('ringing','accepted') order by c.created_at desc limit 5;
end $$;
create function companion_private.start_call(target uuid,call_mode text,device uuid) returns public.calls language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();r public.calls;begin
 if uid is null or not exists(select 1 from public.profiles where id=uid) then raise exception 'Войдите в аккаунт';end if;
 if target is null or call_mode is null or target=uid or call_mode not in ('audio','video') or device is null then raise exception 'Некорректный вызов';end if;
 if not exists(select 1 from public.profiles where id=target) then raise exception 'Пользователь не найден';end if;
 perform id from public.profiles where id in (uid,target) order by id for update;
 update public.calls set status=case when status='ringing' then 'missed' else 'failed' end,ended_at=now() where (caller in(uid,target) or callee in(uid,target)) and ((status='ringing' and created_at<now()-interval '60 seconds') or (status='accepted' and least(caller_seen_at,callee_seen_at)<now()-interval '45 seconds'));
 if exists(select 1 from public.calls where status in('ringing','accepted') and (caller in(uid,target) or callee in(uid,target))) then raise exception 'Линия занята';end if;
 if (select count(*) from public.calls where caller=uid and created_at>now()-interval '1 minute')>=6 then raise exception 'Слишком много вызовов. Подождите минуту';end if;
 insert into public.calls(caller,callee,mode,caller_device) values(uid,target,call_mode,device) returning * into r;return r;
end $$;
create function companion_private.call_action(call uuid,device uuid,action text) returns public.calls language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();r public.calls;begin
 if uid is null or device is null then raise exception 'Войдите в аккаунт';end if;
 select * into r from public.calls where id=call and (caller=uid or callee=uid) for update;
 if not found then raise exception 'Звонок недоступен';end if;
 if r.status not in ('ringing','accepted') then return r;end if;
 if action='accept' then
  if r.callee<>uid then raise exception 'Принять звонок может только получатель';end if;
  if r.status='accepted' and r.callee_device is distinct from device then raise exception 'Звонок принят на другом устройстве';end if;
  if r.created_at<now()-interval '60 seconds' then raise exception 'Время ответа истекло';end if;
  update public.calls set status='accepted',callee_device=device,answered_at=coalesce(answered_at,now()),caller_seen_at=now(),callee_seen_at=now() where id=call returning * into r;
 elsif action='ping' then
  if (uid=r.caller and device is distinct from r.caller_device) or (uid=r.callee and device is distinct from r.callee_device) then raise exception 'Другое устройство';end if;
  update public.calls set caller_seen_at=case when caller=uid then now() else caller_seen_at end,callee_seen_at=case when callee=uid then now() else callee_seen_at end where id=call returning * into r;
 elsif action in ('hangup','decline','fail') then
  if action='decline' and (uid<>r.callee or r.status<>'ringing') then raise exception 'Нельзя отклонить этот звонок';end if;
  update public.calls set status=case when action='decline' then 'declined' when action='fail' then 'failed' else 'ended' end,ended_at=now() where id=call returning * into r;
  delete from public.call_signals where call_id=call;
 else raise exception 'Неизвестное действие';end if;
 return r;
end $$;
create function companion_private.send_call_signal(call uuid,device uuid,signal_kind text,payload jsonb) returns bigint language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();r public.calls;result bigint;begin
 if uid is null or device is null then raise exception 'Войдите в аккаунт';end if;
 select * into r from public.calls where id=call and (caller=uid or callee=uid) for update;
 if not found or r.status not in('ringing','accepted') then raise exception 'Звонок завершён или недоступен';end if;
 if (uid=r.caller and device is distinct from r.caller_device) or (uid=r.callee and device is distinct from r.callee_device) then raise exception 'Другое устройство';end if;
 if signal_kind is null or signal_kind not in ('offer','answer','ice','control') or payload is null or jsonb_typeof(payload)<>'object' or octet_length(payload::text)>65536 then raise exception 'Некорректный сигнал';end if;
 if signal_kind='offer' and (uid<>r.caller or (payload->>'type') is distinct from 'offer' or jsonb_typeof(payload->'sdp') is distinct from 'string') then raise exception 'Некорректное предложение';end if;
 if signal_kind='answer' and (uid<>r.callee or r.status<>'accepted' or (payload->>'type') is distinct from 'answer' or jsonb_typeof(payload->'sdp') is distinct from 'string') then raise exception 'Некорректный ответ';end if;
 if signal_kind='ice' and (jsonb_typeof(payload->'candidate') is distinct from 'string' or octet_length(payload::text)>8192) then raise exception 'Некорректный ICE';end if;
 if (select count(*) from public.call_signals where call_id=call)>=256 then raise exception 'Слишком много сигналов';end if;
 insert into public.call_signals(call_id,sender,kind,data) values(call,uid,signal_kind,payload) returning id into result;return result;
end $$;
revoke all on function companion_private.my_calls(),companion_private.start_call(uuid,text,uuid),companion_private.call_action(uuid,uuid,text),companion_private.send_call_signal(uuid,uuid,text,jsonb) from public,anon;
grant execute on function companion_private.my_calls(),companion_private.start_call(uuid,text,uuid),companion_private.call_action(uuid,uuid,text),companion_private.send_call_signal(uuid,uuid,text,jsonb) to authenticated;
create function public.my_calls() returns setof public.calls language sql security invoker set search_path='' as $$select * from companion_private.my_calls()$$;
create function public.start_call(target uuid,call_mode text,device uuid) returns public.calls language sql security invoker set search_path='' as $$select companion_private.start_call(target,call_mode,device)$$;
create function public.call_action(call uuid,device uuid,action text) returns public.calls language sql security invoker set search_path='' as $$select companion_private.call_action(call,device,action)$$;
create function public.send_call_signal(call uuid,device uuid,signal_kind text,payload jsonb) returns bigint language sql security invoker set search_path='' as $$select companion_private.send_call_signal(call,device,signal_kind,payload)$$;
revoke all on function public.my_calls(),public.start_call(uuid,text,uuid),public.call_action(uuid,uuid,text),public.send_call_signal(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.my_calls(),public.start_call(uuid,text,uuid),public.call_action(uuid,uuid,text),public.send_call_signal(uuid,uuid,text,jsonb) to authenticated;
