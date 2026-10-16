-- МониТорг: уведомления из админки в личные кабинеты (16.10.2026). Повторный запуск безопасен.
--   одному пользователю — kind 'msg' («Сообщение»), приходит всегда, как заявки и отчёты;
--   всем — kind 'promo' («От МониТорга»), кроме гостевого входа и тех, кто выключил в профиле «Предложения и новости» (notify.promo).
-- Пишутся в общую таблицу notifications: когда появится доставка в Telegram, она возьмёт и эти уведомления.
create table if not exists broadcasts (               -- история отправленного из админки
  id bigserial primary key,
  user_id bigint references users on delete set null, -- кому; null — всем
  kind text not null, title text not null, body text, lot text,
  sent int not null default 0,
  created_at timestamptz not null default now()
);
alter table broadcasts enable row level security;
drop policy if exists admin_all on broadcasts;
create policy admin_all on broadcasts for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()));

create or replace function admin_notify(p_user bigint, p_title text, p_body text default null, p_lot text default null)
returns int language plpgsql security definer set search_path = public as $$
declare k text := case when p_user is null then 'promo' else 'msg' end; n int; b bigint;
  t text := left(trim(coalesce(p_title, '')), 120); x text := nullif(left(trim(coalesce(p_body, '')), 1000), '');
  l text := nullif(left(trim(coalesce(p_lot, '')), 200), '');
begin
  if not is_admin() then raise exception 'Нет доступа'; end if;
  if t = '' then raise exception 'Нужен заголовок'; end if;
  if p_user is not null and not exists (select 1 from users where id = p_user) then raise exception 'Нет такого пользователя'; end if;
  insert into broadcasts (user_id, kind, title, body, lot) values (p_user, k, t, x, l) returning id into b;
  insert into notifications (user_id, lot, kind, title, body)
  select u.id, l, k, t, x from users u
  where (p_user is not null and u.id = p_user)
     or (p_user is null and u.login <> 'guest' and notify_on(u.id, 'promo'));
  get diagnostics n = row_count;
  update broadcasts set sent = n where id = b;
  return n;
end $$;
grant execute on function admin_notify(bigint, text, text, text) to anon, authenticated;
