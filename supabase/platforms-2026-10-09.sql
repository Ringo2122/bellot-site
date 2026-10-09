-- 09.10.2026: фильтр «Площадка» — можно выбрать несколько (params.plat = «a.by,b.by»); уведомления по сохранённым поискам учитывают все.
-- Применить: SBP=… SBREF=uuyhhdttxtppzrqtkatp ruby -Eutf-8 tools-local/sbq.rb -f bellot-site/supabase/platforms-2026-10-09.sql
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
      and (coalesce(s.params->>'plat', '') = '' or l.platform = any(string_to_array(s.params->>'plat', ',')))   -- площадок может быть несколько: «a.by,b.by»
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
  -- объект снова на торгах: человек следит за лотом архива, а робот узнал тот же объект в новом лоте (lots.prev, similar.rb)
  insert into notifications (user_id, lot, kind, title, body)
  select distinct on (ul.user_id, l.id) ul.user_id, l.id, 'relist', l.name,
         'Объект снова на торгах: стартовая цена ' || fmt_n(l.price) || ' BYN, приём заявок до ' || fmt_t(l.req_to)
  from user_lots ul join lots l on l.status = 'active' and l.published and ul.lot = any(l.prev)
  where ul.watch and notify_on(ul.user_id, 'status')
    and not exists (select 1 from notifications x where x.user_id = ul.user_id and x.lot = l.id and x.kind = 'relist');
  get diagnostics c = row_count; n := n + c;
  delete from notifications where created_at < now() - interval '180 days';
  return n;
end $$;
