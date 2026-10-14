-- 14.10.2026: сохранённые поиски — «видел до» (seen_at) и одно уведомление на поиск
-- 14.10: когда человек последний раз смотрел новые лоты поиска; новые — появившиеся после этого и им не открытые
alter table saved_searches add column if not exists seen_at timestamptz;
update saved_searches set seen_at = notified_at where seen_at is null;
alter table saved_searches alter column seen_at set default now(), alter column seen_at set not null;

create or replace function cab_tick() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; c int; f int; s record; e bigint := extract(epoch from now())::bigint; lnk text; txt text; nid bigint;
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
  -- сохранённые поиски (14.10): одно уведомление на поиск, а не новое после каждого обхода. c — новые лоты: появились после
  -- прошлого просмотра новых (seen_at) и человек их сам не открывал (user_views); f — из них появились после прошлого
  -- уведомления. Непрочитанное уведомление обновляем (число растёт, поднимается наверх, если есть свежие); новых не осталось —
  -- убираем; прочитано, а потом пришли ещё — новое уведомление
  for s in select * from saved_searches where notify loop
    select count(*), count(*) filter (where l.first_seen > extract(epoch from s.notified_at)) into c, f from lots l
    where l.status = 'active' and l.published and l.first_seen > extract(epoch from s.seen_at)
      and not exists (select 1 from user_views v where v.user_id = s.user_id and v.lot = l.id)
      and (coalesce(s.params->>'sec', '') = '' or l.section = s.params->>'sec')
      and (coalesce(s.params->>'cat', '') = '' or l.section = s.params->>'cat')
      and (coalesce(s.params->>'region', '') = '' or l.region = s.params->>'region')
      and (coalesce(s.params->>'city', '') = '' or l.city = s.params->>'city')
      and (coalesce(s.params->>'plat', '') = '' or l.platform = any(string_to_array(s.params->>'plat', ',')))   -- площадок может быть несколько: «a.by,b.by»
      and (nullif(regexp_replace(coalesce(s.params->>'pmin', ''), '[^0-9.]', '', 'g'), '') is null
           or l.price >= regexp_replace(s.params->>'pmin', '[^0-9.]', '', 'g')::numeric)
      and (nullif(regexp_replace(coalesce(s.params->>'pmax', ''), '[^0-9.]', '', 'g'), '') is null
           or l.price <= regexp_replace(s.params->>'pmax', '[^0-9.]', '', 'g')::numeric)
      and (coalesce(s.params->>'q', '') = '' or l.name ilike '%' || (s.params->>'q') || '%'
           or l.location ilike '%' || (s.params->>'q') || '%')
      and (coalesce(s.params->>'photo', '') = '' or l.photo)
      and (coalesce(s.params->>'mkt', '') = '' or l.market is not null);
    lnk := '#/me/searches/' || s.id;
    txt := c || ' ' || case when c % 10 = 1 and c % 100 <> 11 then 'новый лот'
      when c % 10 between 2 and 4 and c % 100 not between 12 and 14 then 'новых лота' else 'новых лотов' end
      || ' по сохранённому поиску с ' || to_char(s.seen_at at time zone 'Europe/Minsk', 'DD.MM.YYYY');
    select id into nid from notifications where user_id = s.user_id and kind = 'search' and link = lnk and read_at is null
      order by created_at desc limit 1;
    if c = 0 then
      delete from notifications where user_id = s.user_id and kind = 'search' and link = lnk and read_at is null;
    elsif nid is not null then
      update notifications set title = s.name, body = txt, created_at = case when f > 0 then now() else created_at end
      where id = nid and (body is distinct from txt or f > 0);
    elsif f > 0 and notify_on(s.user_id, 'search') then
      insert into notifications (user_id, kind, title, body, link) values (s.user_id, 'search', s.name, txt, lnk);
      n := n + 1;
    end if;
    if f > 0 then update saved_searches set notified_at = now() where id = s.id; end if;
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
