-- 14.10: подраздел, условия торгов и фото в копии каталога; заметка и значения площадки в правках
alter table lots add column if not exists sub text;
alter table lots add column if not exists terms jsonb;
alter table lots add column if not exists pics jsonb;
alter table overrides add column if not exists note text;
alter table overrides add column if not exists base jsonb;
drop view if exists lots_v;
create view lots_v with (security_invoker = true) as
select l.*, o.mod, coalesce(o.pinned, false) as pinned, coalesce(o.fields, '{}'::jsonb) as fields, o.note, o.base,
       o.updated_at as ov_at, (o.fields is not null and o.fields <> '{}'::jsonb) as edited,
       case when o.mod = 'hidden' then 'hidden'
            when o.mod = 'review' then 'queue'
            when o.mod = 'approved' then 'ok'
            when l.hidden_why = 'mod' then 'queue'
            else 'auto' end as mstate
from lots l left join overrides o using (key);
