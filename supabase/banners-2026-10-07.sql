-- МониТорг: счётчик показов и кликов баннеров на главной (07.10.2026). Повторный запуск безопасен. Те же определения — в schema.sql.
-- Показ — баннер хотя бы наполовину на экране (раз за открытие страницы), клик — нажатие. Считаем по дням (минское время),
-- по номеру баннера (bid из конструктора главной). Роботов поисковиков и предпросмотр админки сайт не считает.
create table if not exists banner_stats (
  bid text not null,
  day date not null,
  views integer not null default 0,
  clicks integer not null default 0,
  primary key (bid, day)
);
alter table banner_stats enable row level security;
drop policy if exists admin_all on banner_stats;
create policy admin_all on banner_stats for all using ((select is_admin())) with check ((select is_admin()));

create or replace function banner_hit(p_bid text, p_click boolean default false) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_bid, '') !~ '^[a-z0-9-]{4,40}$' then return; end if;
  insert into banner_stats (bid, day, views, clicks)
  values (p_bid, (now() at time zone 'Europe/Minsk')::date, case when p_click then 0 else 1 end, case when p_click then 1 else 0 end)
  on conflict (bid, day) do update set views = banner_stats.views + excluded.views, clicks = banner_stats.clicks + excluded.clicks;
end $$;
grant execute on function banner_hit(text, boolean) to anon, authenticated;
