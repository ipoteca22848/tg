-- Applied before profile-gifts.sql. Phone strings are normalized to digits for auth.
alter table public.profiles drop constraint profiles_number_check;
alter table public.profiles add constraint profiles_number_check check(number ~ '^[0-9]{10,15}$');
alter table public.profiles add column username text unique check(username is null or username ~ '^[a-z][a-z0-9_]{3,31}$'), add column role text not null default 'user' check(role in ('user','creator')), add column avatar_url text not null default '', add column cover_url text not null default '', add column accent text not null default '#487bf0' check(accent ~ '^#[0-9a-fA-F]{6}$'), add column birthday date, add column city text not null default '' check(char_length(city)<=60), add column status text not null default '' check(char_length(status)<=60);
grant update(username,avatar_url,cover_url,accent,birthday,city,status) on public.profiles to authenticated;
