-- БелЛот: «Сообщить об ошибке» в карточке лота (07.10.2026). Повторный запуск безопасен. Те же определения — в schema.sql.
-- Посетитель пишет, что не так с лотом; сообщение видно в админке («Ошибки в лотах»), счётчик новых — в меню.
create table if not exists lot_reports (
  id bigserial primary key,
  lot text not null,                           -- id лота на сайте
  lot_name text, platform text, url text,
  msg text not null,
  contact text,                                -- как связаться, если посетитель оставил
  user_id bigint references users on delete set null,
  created_at timestamptz not null default now(),
  done boolean not null default false          -- админ разобрался
);
alter table lot_reports enable row level security;
drop policy if exists admin_all on lot_reports;
create policy admin_all on lot_reports for all using ((select is_admin())) with check ((select is_admin()));

create or replace function report_lot(p_lot text, p_msg text, p_contact text default null, p_name text default null,
                                      p_platform text default null, p_url text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(trim(coalesce(p_lot, ''))) < 1 or length(trim(coalesce(p_msg, ''))) < 3 then raise exception 'Опишите, что не так'; end if;
  if (select count(*) from lot_reports where created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Слишком много сообщений, попробуйте позже';
  end if;
  if (select count(*) from lot_reports where lot = trim(p_lot) and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'По этому лоту уже есть сообщения — спасибо, проверим';
  end if;
  insert into lot_reports (lot, lot_name, platform, url, msg, contact, user_id)
  values (left(trim(p_lot), 120), left(p_name, 300), left(p_platform, 60), case when p_url ~* '^https?://' then left(p_url, 500) end,
          left(trim(p_msg), 2000), nullif(left(trim(coalesce(p_contact, '')), 200), ''), cur_user());
end $$;
grant execute on function report_lot(text, text, text, text, text, text) to anon, authenticated;

-- счётчик новых сообщений в меню админки
do $$ begin
  if position('lot_reports' in pg_get_functiondef('public.admin_stats()'::regprocedure)) = 0 then
    execute replace(pg_get_functiondef('public.admin_stats()'::regprocedure),
      $r$'leads_new', (select count(*) from leads where status = 'new'),$r$,
      $r$'leads_new', (select count(*) from leads where status = 'new'),
    'lot_reports', (select count(*) from lot_reports where not done),$r$);
  end if;
end $$;
