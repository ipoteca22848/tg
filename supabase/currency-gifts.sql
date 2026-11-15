-- Internal, non-redeemable currency gifts. Ledger fields are server-only.
alter table public.messages add column currency_gift text check(currency_gift in ('stars','ton')),add column currency_amount bigint,add column currency_request uuid;
alter table public.messages drop constraint messages_kind_check;
alter table public.messages add constraint messages_kind_check check(kind in ('text','image','video','voice','gift','currency'));
alter table public.messages drop constraint message_attachment_shape;
alter table public.messages add constraint message_attachment_shape check(
(kind='text' and media_path is null and gift_receipt is null) or
(kind in ('image','video','voice') and media_path is not null and media_path like sender::text||'/%' and char_length(media_path)<=200 and gift_receipt is null and media_mime is not null and ((kind='image' and media_mime in ('image/jpeg','image/png','image/webp')) or (kind='video' and media_mime in ('video/mp4','video/webm')) or (kind='voice' and media_mime in ('audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav')))) or
(kind='gift' and gift_receipt is not null and media_path is null) or
(kind='currency' and gift_receipt is null and media_path is null));
alter table public.messages add constraint currency_gift_shape check(case when kind='currency' then currency_gift is not null and currency_amount between 1 and 1000000000 and currency_request is not null else currency_gift is null and currency_amount is null and currency_request is null end);
-- Independent ledger preserves idempotency even if a user deletes the chat card.
create table public.currency_gifts(id uuid primary key default gen_random_uuid(),sender uuid not null references public.profiles(id),recipient uuid not null references public.profiles(id),currency text not null check(currency in ('stars','ton')),amount bigint not null check(amount between 1 and 1000000000),note text not null check(char_length(note)<=200),request_id uuid not null,created_at timestamptz not null default now(),unique(sender,request_id),check(sender<>recipient));
alter table public.currency_gifts enable row level security;
revoke all on public.currency_gifts from anon,authenticated;grant select on public.currency_gifts to authenticated;
create policy "currency participants" on public.currency_gifts for select to authenticated using(sender=(select auth.uid()) or recipient=(select auth.uid()));
create index currency_gifts_recipient on public.currency_gifts(recipient,created_at desc);
create function companion_private.send_currency_gift(target uuid,currency text,amount bigint,note text,request uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();creator boolean;result uuid;balance public.wallets;begin
 if uid is null or not exists(select 1 from auth.users where id=uid) then raise exception 'Войдите в аккаунт';end if;
 if target is null or target=uid or currency is null or currency not in('stars','ton') or amount is null or amount not between 1 and 1000000000 or request is null or note is null or char_length(note)>200 then raise exception 'Некорректный подарок';end if;
 if currency='stars' and amount>1000000 then raise exception 'Максимум 1 000 000 звёзд';end if;
 if not exists(select 1 from public.profiles where id=target) then raise exception 'Получатель не найден';end if;
 -- Stable lock order prevents opposite transfers from deadlocking.
 perform user_id from public.wallets where user_id in(uid,target) order by user_id for update;
 select id into result from public.currency_gifts where sender=uid and request_id=request;
 if result is not null then return result;end if;
 select role='creator' into creator from public.profiles where id=uid;
 select * into balance from public.wallets where user_id=uid;
 if not found or creator is null then raise exception 'Баланс недоступен';end if;
 if not creator then
  if (currency='stars' and balance.stars<amount) or (currency='ton' and balance.ton_milli<amount) then raise exception 'Недостаточно средств';end if;
  update public.wallets set stars=stars-case when currency='stars' then amount else 0 end,ton_milli=ton_milli-case when currency='ton' then amount else 0 end where user_id=uid;
 end if;
 update public.wallets set stars=stars+case when currency='stars' then amount else 0 end,ton_milli=ton_milli+case when currency='ton' then amount else 0 end where user_id=target;
 if not found then raise exception 'Баланс получателя недоступен';end if;
 insert into public.currency_gifts(sender,recipient,currency,amount,note,request_id) values(uid,target,currency,amount,note,request) returning id into result;
 insert into public.messages(sender,recipient,text,kind,currency_gift,currency_amount,currency_request) values(uid,target,note,'currency',currency,amount,request);
 return result;
end $$;
revoke all on function companion_private.send_currency_gift(uuid,text,bigint,text,uuid) from public,anon;
grant execute on function companion_private.send_currency_gift(uuid,text,bigint,text,uuid) to authenticated;
create function public.send_currency_gift(target uuid,currency text,amount bigint,note text,request uuid) returns uuid language sql security invoker set search_path='' as $$select companion_private.send_currency_gift(target,currency,amount,note,request)$$;
revoke all on function public.send_currency_gift(uuid,text,bigint,text,uuid) from public,anon;
grant execute on function public.send_currency_gift(uuid,text,bigint,text,uuid) to authenticated;
