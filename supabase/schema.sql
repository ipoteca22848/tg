create schema if not exists companion_private;
revoke all on schema companion_private from public;
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 number text unique not null check(number ~ '^[0-9]{10}$'),
 name text not null check(char_length(name) between 1 and 50),
 bio text not null default '' check(char_length(bio)<=160),
 created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
grant select on public.profiles to authenticated;
grant update(name,bio) on public.profiles to authenticated;
revoke all on public.profiles from anon;
create policy "authenticated directory" on public.profiles for select to authenticated using(true);
create policy "own profile" on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));
create function companion_private.new_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,number,name) values(new.id,split_part(new.email,'@',1),left(coalesce(nullif(new.raw_user_meta_data->>'name',''),'Пользователь'),50));
 return new;
end $$;
revoke all on function companion_private.new_profile() from public,anon,authenticated;
create trigger companion_profile after insert on auth.users for each row execute function companion_private.new_profile();
create table public.messages (
 id uuid primary key default gen_random_uuid(),
 sender uuid not null references public.profiles(id),
 recipient uuid not null references public.profiles(id),
 text text not null check(char_length(text) between 1 and 6000),
 edited boolean not null default false,
 created_at timestamptz not null default now()
);
alter table public.messages enable row level security;
revoke all on public.messages from anon,authenticated;
grant select,delete on public.messages to authenticated;
grant insert(sender,recipient,text) on public.messages to authenticated;
grant update(text,edited) on public.messages to authenticated;
create index messages_sender_time on public.messages(sender,created_at desc);
create index messages_recipient_time on public.messages(recipient,created_at desc);
create policy "participants read" on public.messages for select to authenticated using(sender=(select auth.uid()) or recipient=(select auth.uid()));
create policy "sender creates" on public.messages for insert to authenticated with check(sender=(select auth.uid()));
create policy "sender edits" on public.messages for update to authenticated using(sender=(select auth.uid())) with check(sender=(select auth.uid()));
create policy "sender deletes" on public.messages for delete to authenticated using(sender=(select auth.uid()));
create table public.signup_limits(ip_hash text primary key,window_start timestamptz not null default now(),attempts integer not null default 1);
alter table public.signup_limits enable row level security;
revoke all on public.signup_limits from anon,authenticated;
create function public.consume_signup(ip text) returns boolean language plpgsql security invoker set search_path='' as $$
declare n integer;
begin
 insert into public.signup_limits(ip_hash) values(ip)
 on conflict(ip_hash) do update set
 attempts=case when public.signup_limits.window_start<now()-interval '1 hour' then 1 else public.signup_limits.attempts+1 end,
 window_start=case when public.signup_limits.window_start<now()-interval '1 hour' then now() else public.signup_limits.window_start end
 returning attempts into n;
 return n<=5;
end $$;
revoke all on function public.consume_signup(text) from public,anon,authenticated;
grant execute on function public.consume_signup(text) to service_role;
grant all on public.signup_limits to service_role;

-- Follow-up hardening applied to the live project.
revoke all on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update(name,bio) on public.profiles to authenticated;
alter table public.signup_limits set schema companion_private;
grant usage on schema companion_private to service_role;
create or replace function public.consume_signup(ip text) returns boolean language plpgsql security invoker set search_path='' as $$
declare n integer;
begin
 insert into companion_private.signup_limits(ip_hash) values(ip)
 on conflict(ip_hash) do update set
 attempts=case when companion_private.signup_limits.window_start<now()-interval '1 hour' then 1 else companion_private.signup_limits.attempts+1 end,
 window_start=case when companion_private.signup_limits.window_start<now()-interval '1 hour' then now() else companion_private.signup_limits.window_start end
 returning attempts into n;
 return n<=5;
end $$;
