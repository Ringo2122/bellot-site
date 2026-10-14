-- 14.10: согласие на подборки и новости на почту (необязательная галочка при регистрации и в профиле)
alter table users add column if not exists news_at timestamptz;

create or replace function auth_user_sync() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'); em text := lower(new.email);
begin
  if tg_op = 'INSERT' then
    insert into users (login, email, name, phone, purpose, purpose_note, consent_at, news_at, auth_id, confirmed_at)
    values (em, em, left(nullif(trim(m->>'name'), ''), 120), left(nullif(trim(m->>'phone'), ''), 40),
            left(nullif(trim(m->>'purpose'), ''), 120), left(nullif(trim(m->>'purpose_note'), ''), 300),
            case when m->>'consent' = 'true' then now() end, case when m->>'news' = 'true' then now() end, new.id, new.email_confirmed_at)
    on conflict (login) do update set auth_id = excluded.auth_id, email = excluded.email, name = excluded.name, phone = excluded.phone,
      purpose = excluded.purpose, purpose_note = excluded.purpose_note, consent_at = excluded.consent_at, news_at = excluded.news_at,
      confirmed_at = excluded.confirmed_at;
  else
    update users set login = em, email = em, confirmed_at = new.email_confirmed_at where auth_id = new.id;
  end if;
  return new;
end $$;

create or replace function user_me() returns json
language sql security definer set search_path = public, extensions as $$
  update users set last_seen = now() where id = cur_user() and (last_seen is null or last_seen < now() - interval '10 minutes');
  select json_build_object('id', id, 'login', login, 'name', name, 'email', email, 'phone', phone, 'telegram', telegram,
    'notify', notify, 'created_at', created_at, 'auth', auth_id is not null, 'purpose', purpose, 'purpose_note', purpose_note, 'news', news_at is not null,
    'unread', (select count(*) from notifications n where n.user_id = u.id and n.read_at is null),
    'reports_new', (select count(*) from reports r where r.user_id = u.id and r.read_at is null))
  from users u where id = cur_user()
$$;

create or replace function user_update(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_auth boolean := (select auth_id is not null from users where id = cur_user());
begin
  if cur_user() is null then raise exception 'Войдите в кабинет'; end if;
  if (select login from users where id = cur_user()) = 'guest' then raise exception 'У гостевого входа профиль не меняется'; end if;
  update users set
    name = case when p ? 'name' then left(nullif(trim(p->>'name'), ''), 120) else name end,
    email = case when p ? 'email' and not v_auth then left(nullif(trim(p->>'email'), ''), 120) else email end,
    phone = case when p ? 'phone' then left(nullif(trim(p->>'phone'), ''), 40) else phone end,
    telegram = case when p ? 'telegram' then left(nullif(trim(p->>'telegram'), ''), 60) else telegram end,
    notify = case when p ? 'notify' and jsonb_typeof(p->'notify') = 'object' then p->'notify' else notify end,
    news_at = case when not p ? 'news' then news_at when p->>'news' = 'true' then coalesce(news_at, now()) end
  where id = cur_user();
end $$;
