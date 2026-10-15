-- 15.10: данные «Аналитики» — зашифрованным файлом на сайте (app/statsfile.rb). Здесь — имя и ключ трёх последних файлов.
-- Таблицу видит только робот и админка; ключ выдаёт stats_key() — вошедшим в кабинет или в админку.
create table if not exists stats_file (
  name text primary key,                       -- st/<name>.bin на сайте
  key text not null,                           -- AES-256 + HMAC, 64 байта base64; у каждой сборки свой
  at timestamptz not null default now(),       -- когда подключён (после выкладки сайта)
  meta jsonb                                   -- лотов, итогов, размер — для проверки
);
alter table stats_file enable row level security;
drop policy if exists admin_all on stats_file;
create policy admin_all on stats_file for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()));

create or replace function stats_key() returns json
language sql stable security definer set search_path = public, extensions as $$
  select case when (select cur_user()) is not null or (select is_admin()) then
    (select json_agg(json_build_object('n', name, 'k', key, 'at', at) order by at desc)
       from (select name, key, at from stats_file order by at desc limit 2) s)
  end
$$;
revoke all on function stats_key() from public;
grant execute on function stats_key() to anon, authenticated;
