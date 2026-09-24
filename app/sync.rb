#!/usr/bin/env ruby
# encoding: utf-8
#
# После сборки: копия каталога — в базу админки, отчёт о запуске — туда же.
#   RUN_ID   строка отчёта, которую создал gate.rb
#   JOB_OK   true/false — как прошли предыдущие шаги
# Запускается всегда, даже если сборка упала, — чтобы в админке было видно, что пошло не так.
require 'json'
require 'time'
require_relative 'store'
require_relative 'sb'

exit 0 unless Sb.on?
TMP = File.join(Store::ROOT, 'tmp')
read = ->(f) { (JSON.parse(File.read(File.join(TMP, f), encoding: 'UTF-8')) rescue nil) }

mirror = read.('mirror.json')
if mirror && ENV['JOB_OK'] != 'false'
  t0 = mirror.first && mirror.first['synced']
  Sb.upsert('lots', mirror)
  Sb.delete('lots', "synced=lt.#{t0}") if t0   # лоты, удалённые из памяти робота
  puts "в базу админки: #{mirror.size} лотов"
  # снимок дня для динамики в аналитике: рынок без дублей и скрытых, по площадкам и разделам
  act = mirror.select { |l| l['status'] == 'active' && !%w[dup hidden].include?(l['hidden_why']) }
  cnt = ->(k) { act.group_by { |l| l[k] }.map { |g, v| [g, v.size] }.to_h }
  val = ->(k) { act.group_by { |l| l[k] }.map { |g, v| [g, v.sum { |l| l['price'].to_f }.round] }.to_h }
  Sb.upsert('daily', [{ 'day' => Time.now.strftime('%Y-%m-%d'), 'updated_at' => Time.now.utc.iso8601,
                        'stats' => { 'active' => act.size, 'published' => mirror.count { |l| l['status'] == 'active' && l['published'] },
                                     'value' => act.sum { |l| l['price'].to_f }.round, 'by_platform' => cnt.('platform'),
                                     'by_section' => cnt.('section'), 'value_by_section' => val.('section') } }], 'day')
  # личный кабинет: новые лоты по сохранённым поискам и напоминания о сроках — сразу после обновления каталога
  begin
    n = Sb.req('post', 'rpc/cab_tick', {})
    puts "уведомлений в кабинеты: #{n}"
  rescue StandardError => e
    warn "уведомления кабинета не разосланы: #{e.message}"
  end
end

# отчёт: итоги обхода по площадкам, итоги сборки, строки журнала с ошибками
log = File.exist?(File.join(TMP, 'update.log')) ? File.read(File.join(TMP, 'update.log'), encoding: 'UTF-8') : ''
bad = log.lines.select { |s| s =~ /в списке 0\b|ошибк|error|не разобран|не прочитан|не ответил|недоступ|подозрительно|aborted/i }
tail = (bad.last(40) + ["— последние строки журнала —\n"] + log.lines.last(25)).join
stats = { 'update' => read.('run.json'), 'build' => read.('build.json') }.reject { |_, v| v.nil? }
row = { 'finished_at' => Time.now.utc.iso8601, 'ok' => ENV['JOB_OK'] != 'false', 'stats' => stats, 'log' => tail[0, 20_000] }
if ENV['RUN_ID'].to_s =~ /\A\d+\z/
  Sb.patch('runs', "id=eq.#{ENV['RUN_ID']}", row)
else
  Sb.insert('runs', row.merge('kind' => stats['update'] ? 'collect' : 'build', 'trigger' => 'manual'))
end

# старые отчёты не копим
cut = (Time.now - 60 * 86_400).utc.iso8601
Sb.delete('runs', "at=lt.#{cut}")
Sb.delete('bot_runs', "at=lt.#{cut}")
puts "отчёт о запуске записан (#{row['ok'] ? 'успешно' : 'с ошибкой'})"
