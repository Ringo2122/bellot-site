-- МониТорг: конструктор главной (07.10.2026). Повторный запуск безопасен. Те же определения — в schema.sql.
-- Порядок, видимость и настройки блоков, общий стиль — в settings.home (как остальные настройки сайта).
-- Картинки блоков «Текст с картинкой» и «Баннеры» — здесь: JPEG base64, уменьшенный в браузере; робот при публикации
-- кладёт их файлами media/<id>-<отпечаток>.jpg.
create table if not exists site_media (
  id text primary key,
  data text not null,
  name text,
  updated_at timestamptz not null default now()
);
alter table site_media enable row level security;
drop policy if exists admin_all on site_media;
create policy admin_all on site_media for all using ((select is_admin())) with check ((select is_admin()));

-- «есть неопубликованные изменения» в админке учитывает и картинки главной
do $$ begin
  if position('from site_media) x)' in pg_get_functiondef('public.admin_stats()'::regprocedure)) = 0 then
    execute replace(pg_get_functiondef('public.admin_stats()'::regprocedure), 'from news) x)', 'from news union all select max(updated_at) from site_media) x)');
  end if;
end $$;
