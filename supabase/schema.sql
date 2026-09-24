-- БелЛот: база админки (Supabase). Повторный запуск безопасен.
--
-- Сайт по-прежнему статический: его собирает робот на GitHub. База хранит то, что решает человек
-- (правки лотов, модерация, склейки, настройки, тексты), заявки с сайта и отчёты робота и бота.
-- Робот читает решения при каждой сборке и кладёт сюда копию каталога — по ней работает админка.
--
-- Доступ: вход по логину и паролю (admin_login) выдаёт ключ сессии, админка шлёт его в заголовке
-- x-admin-token. Все таблицы закрыты правилами RLS: читать и писать может только тот, у кого есть
-- живая сессия. В базе хранится не сам ключ, а его хеш. У робота и бота — своя бессрочная сессия.
-- Публично доступна одна функция — submit_lead (форма «Помощь в аукционе»).

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net;

-- ── доступ ──
create table if not exists admin_users (
  login text primary key,
  pass text not null,
  updated_at timestamptz not null default now()
);
create table if not exists admin_sessions (
  token text primary key,                      -- sha256 от ключа, не сам ключ
  login text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists login_attempts (at timestamptz not null default now(), login text, ok boolean);

-- ── каталог: копия, которую кладёт робот при каждой сборке ──
create table if not exists lots (
  key text primary key,
  id text, art text, platform text, section text, name text, price numeric,
  req_to bigint, torg bigint, location text, region text, url text, photo boolean,
  status text, closed bigint, why text, first_seen bigint, market jsonb,
  reasons text[] not null default '{}',        -- почему лот спорный: no_photo, no_price, no_city, rule_deadline, dup_maybe
  dup_with text,                               -- похожий лот на другой площадке (для dup_maybe)
  dup_of text,                                 -- склеен: ключ главной карточки
  alt jsonb,                                   -- у главной карточки — все площадки
  published boolean not null default false,
  hidden_why text,                             -- mod | hidden | dup | plat_off | sec_off
  synced bigint
);
create index if not exists lots_status on lots (status, hidden_why);
-- для аналитики: первая цена (если снижалась), площадь недвижимости, продавец/должник
alter table lots add column if not exists price0 numeric;
alter table lots add column if not exists area_num numeric;
alter table lots add column if not exists debtor text;

-- ── решения человека ──
create table if not exists overrides (
  key text primary key,
  fields jsonb not null default '{}',          -- name, section, price, req_to, torg, location, descr, market
  mod text check (mod in ('approved', 'review', 'hidden')),
  pinned boolean not null default false,
  updated_at timestamptz not null default now()
);
create table if not exists lot_photos (
  key text primary key,
  data text not null,                          -- JPEG в base64, уже уменьшенный в браузере
  updated_at timestamptz not null default now()
);
create table if not exists dup_rules (
  a text not null, b text not null,            -- merge: склеить a и b; split: отделить b от a
  kind text not null check (kind in ('merge', 'split')),
  created_at timestamptz not null default now(),
  primary key (a, b)
);
create table if not exists settings (
  k text primary key,                          -- platforms, sections, min_price, hours, calc, texts, bot, publish_req, mod_since
  v jsonb not null,
  updated_at timestamptz not null default now()
);

-- ── отчёты ──
create table if not exists daily (                -- снимок каталога на конец дня: динамика в аналитике
  day date primary key,
  stats jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists runs (
  id bigserial primary key,
  at timestamptz not null default now(),
  finished_at timestamptz,
  kind text not null,                          -- collect: обход площадок и сборка; build: только сборка
  trigger text,
  ok boolean,
  stats jsonb,
  log text
);
create table if not exists bot_runs (
  id bigserial primary key,
  at timestamptz not null default now(),
  sent int not null default 0,
  stats jsonb,
  errors text
);

-- ── заявки с сайта ──
create table if not exists leads (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  name text not null, phone text not null, email text, lot text,
  status text not null default 'new' check (status in ('new', 'work', 'deal', 'refused')),
  comment text,
  updated_at timestamptz not null default now()
);

-- ── проверка доступа ──
create or replace function hdr_token() returns text
language sql stable set search_path = public, extensions as $$
  select encode(digest(coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-admin-token', ''), 'sha256'), 'hex')
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from admin_sessions where token = hdr_token() and expires_at > now())
$$;

do $$
declare t text;
begin
  foreach t in array array['lots','overrides','lot_photos','dup_rules','settings','runs','bot_runs','leads','daily'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()))', t);
  end loop;
  foreach t in array array['admin_users','admin_sessions','login_attempts'] loop
    execute format('alter table %I enable row level security', t);   -- без правил: только через функции ниже
  end loop;
end $$;

-- Копия каталога вместе с решениями: для списков в админке
drop view if exists lots_v;   -- lots.* раскрывается при создании: новые колонки — только пересозданием
create view lots_v with (security_invoker = true) as
select l.*, o.mod, coalesce(o.pinned, false) as pinned, coalesce(o.fields, '{}'::jsonb) as fields,
       o.updated_at as ov_at, (o.fields is not null and o.fields <> '{}'::jsonb) as edited,
       case when o.mod = 'hidden' then 'hidden'
            when o.mod = 'review' then 'queue'
            when o.mod = 'approved' then 'ok'
            when l.hidden_why = 'mod' then 'queue'
            else 'auto' end as mstate
from lots l left join overrides o using (key);

-- ── вход, выход, пароль ──
create or replace function admin_login(p_login text, p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; tok text; lg text := lower(trim(p_login));
begin
  if (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok) >= 20 then
    raise exception 'Слишком много неудачных попыток. Подождите 15 минут.';
  end if;
  select exists (select 1 from admin_users where login = lg and pass = crypt(p_pass, pass)) into v_ok;
  insert into login_attempts (login, ok) values (left(lg, 60), v_ok);
  delete from login_attempts where at < now() - interval '7 days';
  if not v_ok then return null; end if;
  tok := encode(gen_random_bytes(24), 'hex');
  delete from admin_sessions where expires_at < now();
  insert into admin_sessions (token, login, expires_at) values (encode(digest(tok, 'sha256'), 'hex'), lg, now() + interval '30 days');
  return tok;
end $$;

create or replace function admin_me() returns text
language sql stable security definer set search_path = public, extensions as $$
  select login from admin_sessions where token = hdr_token() and expires_at > now()
$$;

create or replace function admin_logout(p_all boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg text := admin_me();
begin
  if lg is null then return; end if;
  if p_all then delete from admin_sessions where login = lg;
  else delete from admin_sessions where token = hdr_token(); end if;
end $$;

create or replace function admin_passwd(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg text := admin_me();
begin
  if lg is null or lg = 'robot' then raise exception 'Нет доступа'; end if;
  if not exists (select 1 from admin_users where login = lg and pass = crypt(p_old, pass)) then
    raise exception 'Текущий пароль указан неверно';
  end if;
  if length(coalesce(p_new, '')) < 4 then raise exception 'Новый пароль — не короче 4 символов'; end if;
  update admin_users set pass = crypt(p_new, gen_salt('bf')), updated_at = now() where login = lg;
end $$;

-- ── публикация: попросить робота пересобрать сайт ──
-- Робот на GitHub заглядывает сюда каждые 10 минут. Если в админке сохранён ключ GitHub,
-- сборка запускается сразу, без ожидания.
create or replace function request_publish(p_collect boolean default false) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare gh text;
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  insert into settings (k, v, updated_at)
  values ('publish_req', jsonb_build_object('at', extract(epoch from now())::bigint, 'collect', p_collect), now())
  on conflict (k) do update set v = excluded.v, updated_at = now();
  select decrypted_secret into gh from vault.decrypted_secrets where name = 'github_token';
  if gh is null then return 'queued'; end if;
  perform net.http_post(
    url := 'https://api.github.com/repos/Ringo2122/bellot-site/actions/workflows/update.yml/dispatches',
    body := jsonb_build_object('ref', 'main', 'inputs', jsonb_build_object('collect', case when p_collect then 'true' else 'false' end)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || gh, 'Accept', 'application/vnd.github+json',
                                  'User-Agent', 'bellot-admin', 'Content-Type', 'application/json'));
  return 'dispatched';
end $$;

create or replace function set_github_token(p_token text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  delete from vault.secrets where name = 'github_token';
  if coalesce(trim(p_token), '') <> '' then
    perform vault.create_secret(trim(p_token), 'github_token', 'GitHub: запуск сборки сайта из админки');
  end if;
  return coalesce(trim(p_token), '') <> '';
end $$;

-- Сводка для первой страницы админки одним запросом
create or replace function admin_stats() returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare r json;
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  select json_build_object(
    'active', (select count(*) from lots where status = 'active'),
    'published', (select count(*) from lots where status = 'active' and published),
    'queue', (select count(*) from lots_v where status = 'active' and mstate = 'queue'),
    'hidden', (select count(*) from lots_v where mstate = 'hidden'),
    'remarks', (select count(*) from lots where status = 'active' and published and reasons <> '{}'),
    'merged', (select count(*) from lots where status = 'active' and dup_of is not null),
    'archive', (select count(*) from lots where status = 'archive'),
    'leads_new', (select count(*) from leads where status = 'new'),
    'by_platform', (select json_object_agg(platform, n) from (select platform, count(*) n from lots where status = 'active' and published group by 1) x),
    'merged_by_platform', (select json_object_agg(platform, n) from (select platform, count(*) n from lots where status = 'active' and dup_of is not null group by 1) x),
    'changed_at', (select max(t) from (select max(updated_at) t from overrides union all select max(updated_at) from settings where k not in ('publish_req', 'bot', 'hours', 'min_price', 'cab_stats')
                     union all select max(created_at) from dup_rules union all select max(updated_at) from lot_photos) x),
    'last_build', (select max(at) from runs),
    'github', exists (select 1 from vault.secrets where name = 'github_token')
  ) into r;
  return r;
end $$;

-- ── форма «Помощь в аукционе»: единственное, что доступно посетителю сайта ──
create or replace function submit_lead(p_name text, p_phone text, p_email text default null, p_lot text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
  if length(trim(coalesce(p_name, ''))) < 1 or length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 9 then
    raise exception 'Укажите имя и телефон';
  end if;
  if (select count(*) from leads where created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Слишком много заявок, попробуйте позже';
  end if;
  insert into leads (name, phone, email, lot)
  values (left(trim(p_name), 120), left(trim(p_phone), 40), nullif(left(trim(coalesce(p_email, '')), 120), ''), nullif(left(trim(coalesce(p_lot, '')), 120), ''))
  returning leads.id into v_id;
  return v_id;
end $$;


-- ════════════════════ ЛИЧНЫЙ КАБИНЕТ ════════════════════
-- Вход посетителя — так же, как в админку: user_login выдаёт ключ сессии, сайт шлёт его в заголовке
-- x-user-token. Каждый видит только свои строки (правило own), админ — всё (admin_all).
-- Пока один гостевой вход guest/guest; регистрация по почте — позже.

create table if not exists users (
  id bigserial primary key,
  login text unique not null,
  pass text not null,
  name text, email text, phone text, telegram text,
  notify jsonb not null default '{}',          -- выключенные виды уведомлений: {"price": false, …}
  created_at timestamptz not null default now(),
  last_seen timestamptz
);
create table if not exists user_sessions (
  token text primary key,                      -- sha256 от ключа
  user_id bigint not null references users on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create or replace function cur_user() returns bigint
language sql stable security definer set search_path = public, extensions as $$
  select user_id from user_sessions
  where token = encode(digest(coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-user-token', ''), 'sha256'), 'hex')
    and expires_at > now()
$$;

-- избранное, слежение, своя воронка и заметка по лоту (lot — id лота на сайте)
create table if not exists user_lots (
  user_id bigint not null default cur_user() references users on delete cascade,
  lot text not null,
  fav boolean not null default false,
  watch boolean not null default false,
  stage text,                                  -- look, visit, apply, bid, won, drop
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, lot)
);
create index if not exists user_lots_lot on user_lots (lot);
create table if not exists user_views (
  user_id bigint not null default cur_user() references users on delete cascade,
  lot text not null,
  at timestamptz not null default now(),
  primary key (user_id, lot)
);
create table if not exists saved_searches (
  id bigserial primary key,
  user_id bigint not null default cur_user() references users on delete cascade,
  name text not null,
  params jsonb not null default '{}',          -- sec, cat, q, region, pmin, pmax, dfrom, dto, plat, photo, mkt
  notify boolean not null default true,
  notified_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table if not exists notifications (
  id bigserial primary key,
  user_id bigint not null references users on delete cascade,
  lot text, kind text not null, title text, body text, link text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists notifications_user on notifications (user_id, created_at desc);
create table if not exists reports (               -- отчёты по объектам от БелЛота
  id bigserial primary key,
  user_id bigint not null references users on delete cascade,
  lot text, lot_name text, title text not null, body text, link text,
  file_name text, file_type text, file_size int,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create table if not exists report_files (report_id bigint primary key references reports on delete cascade, data text not null);
alter table leads add column if not exists user_id bigint references users on delete set null;
alter table leads add column if not exists service text;
alter table leads add column if not exists lot_name text;
alter table leads add column if not exists lot_id text;   -- id лота на сайте

do $$
declare t text;
begin
  foreach t in array array['users','user_sessions','user_lots','user_views','saved_searches','notifications','reports','report_files'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()))', t);
  end loop;
  foreach t in array array['user_lots','user_views','saved_searches'] loop
    execute format('drop policy if exists own on %I', t);
    execute format('create policy own on %I for all to anon, authenticated using (user_id = (select cur_user())) with check (user_id = (select cur_user()))', t);
  end loop;
  foreach t in array array['notifications','reports'] loop
    execute format('drop policy if exists own_read on %I', t);
    execute format('create policy own_read on %I for select to anon, authenticated using (user_id = (select cur_user()))', t);
    execute format('drop policy if exists own_mark on %I', t);
    execute format('create policy own_mark on %I for update to anon, authenticated using (user_id = (select cur_user())) with check (user_id = (select cur_user()))', t);
  end loop;
end $$;
drop policy if exists own_del on notifications;
create policy own_del on notifications for delete to anon, authenticated using (user_id = (select cur_user()));
drop policy if exists own_read on report_files;
create policy own_read on report_files for select to anon, authenticated
  using (exists (select 1 from reports r where r.id = report_id and r.user_id = (select cur_user())));
drop policy if exists own_read on leads;
create policy own_read on leads for select to anon, authenticated using (user_id is not null and user_id = (select cur_user()));
-- кабинет: аналитика рынка по копии каталога и снимкам дня, настройка видимых блоков
drop policy if exists user_read on lots;
create policy user_read on lots for select to anon, authenticated using ((select cur_user()) is not null);
drop policy if exists user_read on daily;
create policy user_read on daily for select to anon, authenticated using ((select cur_user()) is not null);
drop policy if exists user_read on settings;
create policy user_read on settings for select to anon, authenticated using (k = 'cab_stats' and (select cur_user()) is not null);

-- ── вход, профиль ──
create or replace function user_login(p_login text, p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; tok text; lg text := lower(trim(p_login));
begin
  if (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok and login like 'u:%') >= 30 then
    raise exception 'Слишком много неудачных попыток. Подождите 15 минут.';
  end if;
  select id into v_id from users where login = lg and pass = crypt(p_pass, pass);
  insert into login_attempts (login, ok) values ('u:' || left(lg, 58), v_id is not null);
  if v_id is null then return null; end if;
  tok := encode(gen_random_bytes(24), 'hex');
  delete from user_sessions where expires_at < now();
  insert into user_sessions (token, user_id, expires_at) values (encode(digest(tok, 'sha256'), 'hex'), v_id, now() + interval '90 days');
  update users set last_seen = now() where id = v_id;
  return tok;
end $$;

create or replace function user_me() returns json
language sql security definer set search_path = public, extensions as $$
  update users set last_seen = now() where id = cur_user() and (last_seen is null or last_seen < now() - interval '10 minutes');
  select json_build_object('id', id, 'login', login, 'name', name, 'email', email, 'phone', phone, 'telegram', telegram,
    'notify', notify, 'created_at', created_at,
    'unread', (select count(*) from notifications n where n.user_id = u.id and n.read_at is null),
    'reports_new', (select count(*) from reports r where r.user_id = u.id and r.read_at is null))
  from users u where id = cur_user()
$$;

create or replace function user_logout() returns void
language sql security definer set search_path = public, extensions as $$
  delete from user_sessions where token = encode(digest(coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-user-token', ''), 'sha256'), 'hex')
$$;

create or replace function user_update(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if cur_user() is null then raise exception 'Войдите в кабинет'; end if;
  update users set
    name = case when p ? 'name' then left(nullif(trim(p->>'name'), ''), 120) else name end,
    email = case when p ? 'email' then left(nullif(trim(p->>'email'), ''), 120) else email end,
    phone = case when p ? 'phone' then left(nullif(trim(p->>'phone'), ''), 40) else phone end,
    telegram = case when p ? 'telegram' then left(nullif(trim(p->>'telegram'), ''), 60) else telegram end,
    notify = case when p ? 'notify' and jsonb_typeof(p->'notify') = 'object' then p->'notify' else notify end
  where id = cur_user();
end $$;

create or replace function user_passwd(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint := cur_user(); lg text;
begin
  select login into lg from users where id = v_id;
  if lg is null then raise exception 'Войдите в кабинет'; end if;
  if lg = 'guest' then raise exception 'У гостевого входа пароль не меняется'; end if;
  if not exists (select 1 from users where id = v_id and pass = crypt(p_old, pass)) then raise exception 'Текущий пароль указан неверно'; end if;
  if length(coalesce(p_new, '')) < 6 then raise exception 'Новый пароль — не короче 6 символов'; end if;
  update users set pass = crypt(p_new, gen_salt('bf')) where id = v_id;
end $$;

-- заявка с сайта: если посетитель вошёл в кабинет — привязываем к нему
drop function if exists submit_lead(text, text, text, text);
drop function if exists submit_lead(text, text, text, text, text, text);
create or replace function submit_lead(p_name text, p_phone text, p_email text default null, p_lot text default null,
                                       p_service text default null, p_lot_name text default null, p_lot_id text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint;
begin
  if length(trim(coalesce(p_name, ''))) < 1 or length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 9 then
    raise exception 'Укажите имя и телефон';
  end if;
  if (select count(*) from leads where created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Слишком много заявок, попробуйте позже';
  end if;
  insert into leads (name, phone, email, lot, service, lot_name, lot_id, user_id)
  values (left(trim(p_name), 120), left(trim(p_phone), 40), nullif(left(trim(coalesce(p_email, '')), 120), ''),
          nullif(left(trim(coalesce(p_lot, '')), 120), ''), nullif(left(trim(coalesce(p_service, '')), 120), ''),
          nullif(left(trim(coalesce(p_lot_name, '')), 300), ''), nullif(left(trim(coalesce(p_lot_id, '')), 120), ''), cur_user())
  returning leads.id into v_id;
  return v_id;
end $$;

-- ── уведомления ──
-- виды: price (цена), dates (срок заявок, дата торгов), status (завершён, снят, снова на торгах),
-- remind (напоминания о сроке), search (новые лоты по сохранённому поиску); заявки и отчёты — всегда
create or replace function notify_on(u bigint, k text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (notify->>k)::boolean from users where id = u), true)
$$;
create or replace function fmt_n(n numeric) returns text language sql immutable as $$
  select replace(to_char(round(n), 'FM999,999,999,990'), ',', ' ')
$$;
create or replace function fmt_t(t bigint) returns text language sql stable as $$
  select to_char(to_timestamp(t) at time zone 'Europe/Minsk', 'DD.MM.YYYY HH24:MI')
$$;

create or replace function push_watch(p_lot text, p_name text, p_kind text, p_group text, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, lot, kind, title, body)
  select ul.user_id, p_lot, p_kind, p_name, p_body from user_lots ul
  where ul.lot = p_lot and ul.watch and notify_on(ul.user_id, p_group)
$$;

-- копия каталога обновилась → тем, кто следит за лотом, приходит уведомление
create or replace function lots_watch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.id is null or not exists (select 1 from user_lots where lot = new.id and watch) then return new; end if;
  if new.price is distinct from old.price and coalesce(old.price, 0) > 0 and coalesce(new.price, 0) > 0 then
    perform push_watch(new.id, new.name, case when new.price < old.price then 'price_down' else 'price_up' end, 'price',
      format('Цена %s: %s → %s BYN (%s%s%%)', case when new.price < old.price then 'снижена' else 'повышена' end,
             fmt_n(old.price), fmt_n(new.price), case when new.price > old.price then '+' else '' end,
             round((new.price - old.price) / old.price * 100)));
  end if;
  if new.status = 'active' and old.status = 'active' and new.req_to is distinct from old.req_to and old.req_to is not null then
    perform push_watch(new.id, new.name, 'deadline', 'dates', 'Срок приёма заявок изменён: теперь до ' || fmt_t(new.req_to));
  end if;
  if new.torg is distinct from old.torg and old.torg is not null and new.torg is not null then
    perform push_watch(new.id, new.name, 'torg', 'dates', 'Дата торгов изменена: ' || fmt_t(new.torg));
  end if;
  if new.status is distinct from old.status then
    if new.status = 'archive' then
      perform push_watch(new.id, new.name, 'closed', 'status',
        case when new.why = 'removed' then 'Лот снят с площадки' else 'Приём заявок завершён' end);
    elsif new.status = 'active' then
      perform push_watch(new.id, new.name, 'reopened', 'status', 'Лот снова на торгах: приём заявок до ' || fmt_t(new.req_to));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists lots_watch on lots;
create trigger lots_watch after update on lots for each row
  when (old.price is distinct from new.price or old.req_to is distinct from new.req_to
        or old.torg is distinct from new.torg or old.status is distinct from new.status)
  execute function lots_watch();

-- статус заявки на помощь изменился → уведомление в кабинет
create or replace function leads_watch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is not null and new.status is distinct from old.status then
    insert into notifications (user_id, lot, kind, title, body, link)
    values (new.user_id, null, 'order', coalesce(new.lot_name, new.service, 'Заявка на помощь'),
      'Статус заявки: ' || case new.status when 'work' then 'в работе' when 'deal' then 'сделка' when 'refused' then 'закрыта' else 'новая' end,
      '#/me/orders');
  end if;
  return new;
end $$;
drop trigger if exists leads_watch on leads;
create trigger leads_watch after update on leads for each row execute function leads_watch();

-- новый отчёт → уведомление
create or replace function reports_watch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (user_id, lot, kind, title, body, link)
  values (new.user_id, new.lot, 'report', new.title, 'Новый отчёт от БелЛота' || coalesce(' по лоту «' || left(new.lot_name, 80) || '»', ''), '#/me/reports/' || new.id);
  return new;
end $$;
drop trigger if exists reports_watch on reports;
create trigger reports_watch after insert on reports for each row execute function reports_watch();

-- Раз в полчаса (pg_cron) и после каждой сборки сайта: напоминания о сроках и новые лоты по сохранённым поискам
create or replace function cab_tick() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; c int; s record; e bigint := extract(epoch from now())::bigint;
begin
  if session_user = 'authenticator' and not is_admin() then raise exception 'Нет доступа'; end if;
  insert into notifications (user_id, lot, kind, title, body)
  select ul.user_id, l.id, r.kind, l.name, r.txt || fmt_t(l.req_to)
  from user_lots ul join lots l on l.id = ul.lot and l.status = 'active' and l.published
  join (values ('remind3', 86400, 3 * 86400, 'До окончания приёма заявок меньше трёх дней: до '),
               ('remind1', 0, 86400, 'Последние сутки приёма заявок: до ')) r(kind, a, b, txt)
    on l.req_to > e + r.a and l.req_to <= e + r.b
  where (ul.fav or ul.watch) and notify_on(ul.user_id, 'remind')
    and not exists (select 1 from notifications x where x.user_id = ul.user_id and x.lot = l.id and x.kind = r.kind
                    and x.created_at > now() - interval '14 days');
  get diagnostics c = row_count; n := n + c;
  for s in select * from saved_searches where notify loop
    select count(*) into c from lots l
    where l.status = 'active' and l.published and l.first_seen > extract(epoch from s.notified_at)
      and (coalesce(s.params->>'sec', '') = '' or l.section = s.params->>'sec')
      and (coalesce(s.params->>'cat', '') = '' or l.section = s.params->>'cat')
      and (coalesce(s.params->>'region', '') = '' or l.region = s.params->>'region')
      and (coalesce(s.params->>'plat', '') = '' or l.platform = s.params->>'plat')
      and (nullif(regexp_replace(coalesce(s.params->>'pmin', ''), '[^0-9.]', '', 'g'), '') is null
           or l.price >= regexp_replace(s.params->>'pmin', '[^0-9.]', '', 'g')::numeric)
      and (nullif(regexp_replace(coalesce(s.params->>'pmax', ''), '[^0-9.]', '', 'g'), '') is null
           or l.price <= regexp_replace(s.params->>'pmax', '[^0-9.]', '', 'g')::numeric)
      and (coalesce(s.params->>'q', '') = '' or l.name ilike '%' || (s.params->>'q') || '%'
           or l.location ilike '%' || (s.params->>'q') || '%')
      and (coalesce(s.params->>'photo', '') = '' or l.photo)
      and (coalesce(s.params->>'mkt', '') = '' or l.market is not null);
    if c > 0 and notify_on(s.user_id, 'search') then
      insert into notifications (user_id, kind, title, body, link)
      values (s.user_id, 'search', s.name, c || ' ' || case when c % 10 = 1 and c % 100 <> 11 then 'новый лот'
        when c % 10 between 2 and 4 and c % 100 not between 12 and 14 then 'новых лота' else 'новых лотов' end || ' по сохранённому поиску',
        '#/me/searches/' || s.id);
      n := n + 1;
    end if;
    update saved_searches set notified_at = now() where id = s.id;
  end loop;
  delete from notifications where created_at < now() - interval '180 days';
  return n;
end $$;
