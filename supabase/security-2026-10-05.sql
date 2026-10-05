-- БелЛот: исправления безопасности по ревизии кода 05.10.2026. Повторный запуск безопасен.
-- Те же определения — в schema.sql (он остаётся полным описанием базы); этот файл — чтобы применить только правки.
--
-- 1. Функции базы по умолчанию может вызвать любой посетитель сайта (через публичный ключ). Среди них была push_watch:
--    через неё кто угодно мог разослать пользователям кабинета уведомление с любым текстом. Теперь вызывать можно
--    только то, что нужно сайту, админке и роботу; остальное — только изнутри базы (триггеры, расписание).
-- 2. Защита от перебора паролей считала неудачные входы по всем логинам вместе: 20 неверных попыток кем угодно
--    за 15 минут закрывали вход и настоящему админу. Теперь — по каждому логину отдельно (10 попыток) и общий потолок 200.
-- 3. Гостевой вход (guest/guest) общий: заявка, отправленная из-под него, с именем и телефоном была видна всем, кто
--    зайдёт гостем, а профиль гостя мог поменять любой. Теперь заявки гостя к нему не привязываются, профиль не меняется.
-- 4. Заявки: не больше 3 с одного номера за час (против спама), общий потолок поднят до 60 за 10 минут.
-- 5. Пароль админа — не короче 10 символов (было 4).

-- ── 2. вход: перебор считаем по логину ──
create or replace function admin_login(p_login text, p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; tok text; lg text := lower(trim(p_login));
begin
  if (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok and login = left(lg, 60)) >= 10
     or (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok and login not like 'u:%') >= 200 then
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

create or replace function user_login(p_login text, p_pass text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; tok text; lg text := lower(trim(p_login));
begin
  if (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok and login = 'u:' || left(lg, 58)) >= 10
     or (select count(*) from login_attempts where at > now() - interval '15 minutes' and not ok and login like 'u:%') >= 200 then
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

-- ── 5. пароль админа — от 10 символов ──
create or replace function admin_passwd(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare lg text := admin_me();
begin
  if lg is null or lg = 'robot' then raise exception 'Нет доступа'; end if;
  if not exists (select 1 from admin_users where login = lg and pass = crypt(p_old, pass)) then
    raise exception 'Текущий пароль указан неверно';
  end if;
  if length(coalesce(p_new, '')) < 10 then raise exception 'Новый пароль — не короче 10 символов'; end if;
  update admin_users set pass = crypt(p_new, gen_salt('bf')), updated_at = now() where login = lg;
end $$;

-- ── 3. гостевой вход: профиль не меняется, заявки к нему не привязываются ──
create or replace function user_update(p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if cur_user() is null then raise exception 'Войдите в кабинет'; end if;
  if (select login from users where id = cur_user()) = 'guest' then raise exception 'У гостевого входа профиль не меняется'; end if;
  update users set
    name = case when p ? 'name' then left(nullif(trim(p->>'name'), ''), 120) else name end,
    email = case when p ? 'email' then left(nullif(trim(p->>'email'), ''), 120) else email end,
    phone = case when p ? 'phone' then left(nullif(trim(p->>'phone'), ''), 40) else phone end,
    telegram = case when p ? 'telegram' then left(nullif(trim(p->>'telegram'), ''), 60) else telegram end,
    notify = case when p ? 'notify' and jsonb_typeof(p->'notify') = 'object' then p->'notify' else notify end
  where id = cur_user();
end $$;

-- ── 3, 4. заявка: гость не привязывается, не больше 3 с одного номера за час ──
create or replace function submit_lead(p_name text, p_phone text, p_email text default null, p_lot text default null,
                                       p_service text default null, p_lot_name text default null, p_lot_id text default null,
                                       p_msg text default null) returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_user bigint := cur_user(); v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(trim(coalesce(p_name, ''))) < 1 or length(v_digits) < 9 then
    raise exception 'Укажите имя и телефон';
  end if;
  if (select count(*) from leads where created_at > now() - interval '10 minutes') >= 60
     or (select count(*) from leads where created_at > now() - interval '1 hour' and regexp_replace(phone, '\D', '', 'g') = v_digits) >= 3 then
    raise exception 'Слишком много заявок, попробуйте позже';
  end if;
  if (select login from users where id = v_user) = 'guest' then v_user := null; end if;
  insert into leads (name, phone, email, lot, service, lot_name, lot_id, msg, user_id)
  values (left(trim(p_name), 120), left(trim(p_phone), 40), nullif(left(trim(coalesce(p_email, '')), 120), ''),
          nullif(left(trim(coalesce(p_lot, '')), 120), ''), nullif(left(trim(coalesce(p_service, '')), 120), ''),
          nullif(left(trim(coalesce(p_lot_name, '')), 300), ''), nullif(left(trim(coalesce(p_lot_id, '')), 120), ''),
          nullif(left(trim(coalesce(p_msg, '')), 2000), ''), v_user)
  returning leads.id into v_id;
  return v_id;
end $$;

-- заявки, уже привязанные к гостю, и профиль гостя — убрать с общего обозрения
update leads set user_id = null where user_id = (select id from users where login = 'guest');
update users set name = 'Гость', email = null, phone = null, telegram = null where login = 'guest';

-- ── 1. кто может вызывать функции базы ──
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
-- право «всем» на новые функции Postgres даёт глобально, по схеме его не отозвать: без этой строки новая функция снова
-- доступна любому посетителю. Теперь каждую новую функцию для сайта нужно открывать явно (grant execute … to anon, authenticated).
alter default privileges revoke execute on functions from public;
do $$
declare f text;
begin
  foreach f in array array[
    -- проверки доступа: их вызывают правила таблиц (RLS) и значения по умолчанию от имени посетителя
    'hdr_token()', 'is_admin()', 'cur_user()',
    -- админка (каждая сама проверяет сессию админа)
    'admin_login(text, text)', 'admin_me()', 'admin_logout(boolean)', 'admin_passwd(text, text)',
    'request_publish(boolean)', 'set_github_token(text)', 'admin_stats()',
    -- сайт: форма заявки, ошибки у посетителей, личный кабинет
    'submit_lead(text, text, text, text, text, text, text, text)', 'report_error(text, text, text, text)',
    'user_login(text, text)', 'user_me()', 'user_logout()', 'user_update(jsonb)', 'user_passwd(text, text)',
    -- робот после сборки (проверяет сессию админа)
    'cab_tick()'
  ] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
