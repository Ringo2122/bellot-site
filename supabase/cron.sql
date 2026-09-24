-- БелЛот: расписание в базе (pg_cron). Раз в полчаса — напоминания о сроках по избранному
-- и уведомления о новых лотах по сохранённым поискам (cab_tick). Повторный запуск безопасен.
create extension if not exists pg_cron;
select cron.schedule('bellot-cab-tick', '*/30 * * * *', 'select public.cab_tick()');
