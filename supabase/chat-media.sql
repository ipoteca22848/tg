-- Private attachments and server-authenticated gift messages.
alter table public.messages add column kind text not null default 'text' check(kind in ('text','image','video','voice','gift')), add column media_path text, add column media_mime text, add column media_name text, add column media_duration_ms integer not null default 0 check(media_duration_ms between 0 and 1800000), add column media_waveform jsonb not null default '[]'::jsonb check(jsonb_typeof(media_waveform)='array' and jsonb_array_length(media_waveform)<=64), add column gift_receipt uuid references public.profile_gifts(id);
alter table public.messages drop constraint messages_text_check;
alter table public.messages add constraint message_text_length check(char_length(text)<=6000 and (kind<>'text' or char_length(btrim(text))>=1));
alter table public.messages add constraint message_attachment_shape check(
 (kind='text' and media_path is null and gift_receipt is null) or
 (kind in ('image','video','voice') and media_path is not null and media_path like sender::text||'/%' and char_length(media_path)<=200 and gift_receipt is null and media_mime is not null and ((kind='image' and media_mime in ('image/jpeg','image/png','image/webp')) or (kind='video' and media_mime in ('video/mp4','video/webm')) or (kind='voice' and media_mime in ('audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav')))) or
 (kind='gift' and gift_receipt is not null and media_path is null)
);
alter table public.messages add constraint media_name_length check(media_name is null or char_length(media_name)<=180);
create unique index messages_media_path_unique on public.messages(media_path) where media_path is not null;
create unique index messages_gift_receipt_unique on public.messages(gift_receipt) where gift_receipt is not null;
grant insert(kind,media_path,media_mime,media_name,media_duration_ms,media_waveform) on public.messages to authenticated;
alter policy "sender creates" on public.messages with check(sender=(select auth.uid()) and kind in ('text','image','video','voice') and gift_receipt is null);
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('chat-media','chat-media',false,26214400,array['image/jpeg','image/png','image/webp','video/mp4','video/webm','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav']);
create policy "chat media upload own" on storage.objects for insert to authenticated with check(bucket_id='chat-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "chat media read participants" on storage.objects for select to authenticated using(bucket_id='chat-media' and ((storage.foldername(name))[1]=(select auth.uid())::text or exists(select 1 from public.messages m where m.media_path=storage.objects.name and (m.sender=(select auth.uid()) or m.recipient=(select auth.uid())))));
create policy "chat media delete own" on storage.objects for delete to authenticated using(bucket_id='chat-media' and (storage.foldername(name))[1]=(select auth.uid())::text);

create or replace function companion_private.purchase_gift(item text,target uuid,pay_with text,message text,request uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); w public.wallets; g public.gift_catalog; result uuid; creator boolean; price integer;
begin
 if uid is null then raise exception 'Войдите в аккаунт'; end if;
 select role='creator' into creator from public.profiles where id=uid;
 if creator is null then raise exception 'Аккаунт не найден'; end if;
 if char_length(message)>200 then raise exception 'Подпись до 200 символов'; end if;
 if not exists(select 1 from public.profiles where id=target) then raise exception 'Получатель не найден'; end if;
 select * into g from public.gift_catalog where id=item and active;
 if not found then raise exception 'Подарок недоступен'; end if;
 if pay_with not in ('stars','ton') then raise exception 'Неизвестный тестовый баланс'; end if;
 select * into w from public.wallets where user_id=uid for update;
 if not found then raise exception 'Баланс не найден'; end if;
 select id into result from public.profile_gifts where sender=uid and request_id=request;
 if result is not null then return result; end if;
 price:=case when pay_with='stars' then g.stars else g.ton_milli end;
 if not creator then
  if (pay_with='stars' and w.stars<price) or (pay_with='ton' and w.ton_milli<price) then raise exception 'Недостаточно тестовых средств'; end if;
  update public.wallets set stars=stars-case when pay_with='stars' then price else 0 end,ton_milli=ton_milli-case when pay_with='ton' then price else 0 end where user_id=uid;
 end if;
 insert into public.profile_gifts(gift_id,sender,recipient,note,currency,amount,request_id) values(item,uid,target,coalesce(message,''),pay_with,price,request) returning id into result;
 insert into public.messages(sender,recipient,text,kind,gift_receipt) values(uid,target,'Подарок: '||g.name,'gift',result);
 return result;
end $$;
