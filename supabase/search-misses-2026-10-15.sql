-- 15.10: поиски по каталогу без результатов — для админки (Аналитика → Служебное). Только текст запроса и счётчик,
-- без адреса и браузера посетителя; хранится 90 дней.
create table if not exists search_misses (
  q text primary key,
  n int not null default 1,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now()
);
alter table search_misses enable row level security;
drop policy if exists admin_all on search_misses;
create policy admin_all on search_misses for all to anon, authenticated using ((select is_admin())) with check ((select is_admin()));

create or replace function search_miss(p_q text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := lower(left(trim(coalesce(p_q, '')), 100));
begin
  if length(v) < 3 then return; end if;
  if (select count(*) from search_misses where last_at > now() - interval '1 hour') >= 300 then return; end if;
  insert into search_misses (q) values (v) on conflict (q) do update set n = search_misses.n + 1, last_at = now();
  delete from search_misses where last_at < now() - interval '90 days';
end $$;
revoke all on function search_miss(text) from public;
grant execute on function search_miss(text) to anon, authenticated;
