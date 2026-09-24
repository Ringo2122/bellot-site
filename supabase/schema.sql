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
  foreach t in array array['lots','overrides','lot_photos','dup_rules','settings','runs','bot_runs','leads'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()))', t);
  end loop;
  foreach t in array array['admin_users','admin_sessions','login_attempts'] loop
    execute format('alter table %I enable row level security', t);   -- без правил: только через функции ниже
  end loop;
end $$;

-- Копия каталога вместе с решениями: для списков в админке
create or replace view lots_v with (security_invoker = true) as
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
    'changed_at', (select max(t) from (select max(updated_at) t from overrides union all select max(updated_at) from settings where k not in ('publish_req', 'bot', 'hours', 'min_price')
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

