#!/usr/bin/env ruby
# encoding: utf-8
#
# «Пора ли работать?» GitHub запускает робота каждые 10 минут; здесь решаем, что делать:
#   collect — обойти площадки и пересобрать сайт: наступил час из настройки «hours» (по умолчанию 11 и 18)
#             и после него обхода ещё не было, либо в админке нажали «Обновить с площадок»
#   build   — только пересобрать сайт: в админке нажали «Опубликовать изменения»
# Ручной запуск и правка кода — всегда сборка. Решение и номер запуска уходят в $GITHUB_OUTPUT,
# а в базе появляется строка отчёта, которую потом дополнит sync.rb.
require 'time'
require_relative 'sb'

ev = ENV['EVENT'].to_s
now = Time.now
collect = false
build = false
trigger = ev

def last_slot(hours, now)
  (0..2).each do |d|
    day = now - d * 86_400
    hours.sort.reverse_each do |h|
      t = Time.new(day.year, day.month, day.day, h)
      return t if t <= now
    end
  end
  now - 3 * 86_400
end

if Sb.on?
  begin
    st = Sb.settings
    hours = Array(st['hours']).map(&:to_i).select { |h| h.between?(0, 23) }
    hours = [11, 18] if hours.empty?
    last_c = Sb.get('runs?kind=eq.collect&select=at,finished_at&order=at.desc&limit=1').first
    last_any = Sb.get('runs?select=at&order=at.desc&limit=1').first
    lc = last_c ? Time.parse(last_c['at']) : Time.at(0)
    la = last_any ? Time.parse(last_any['at']) : Time.at(0)
    # запуск начался, но так и не отчитался за 90 минут — считаем, что он умер, и повторяем
    dead = last_c && last_c['finished_at'].nil? && now - lc > 90 * 60
    req = st['publish_req'] || {}
    asked = req['at'].to_i > la.to_i
    if ev == 'schedule'
      collect = lc < last_slot(hours, now) || dead
      trigger = 'schedule'
      if asked
        collect ||= req['collect'] == true
        trigger = 'admin' unless collect && lc < last_slot(hours, now)
      end
      build = collect || asked
    else
      collect = ev == 'workflow_dispatch' && ENV['INPUT_COLLECT'] == 'true'
      build = true
      trigger = asked ? 'admin' : ev
    end
  rescue StandardError => e
    warn "база админки недоступна: #{e.message}"
    Sb.instance_variable_set(:@settings, nil)
    # без базы — старое расписание
    collect = ev == 'schedule' ? [11, 18].include?(now.hour) && now.min < 10 : ENV['INPUT_COLLECT'] == 'true'
    build = collect || ev != 'schedule'
  end
else
  collect = ev == 'schedule' ? [11, 18].include?(now.hour) && now.min < 10 : ENV['INPUT_COLLECT'] == 'true'
  build = collect || ev != 'schedule'
end

run_id = ''
if build && Sb.on?
  begin
    run_id = Sb.insert('runs', { 'kind' => collect ? 'collect' : 'build', 'trigger' => trigger })['id'].to_s
  rescue StandardError => e
    warn "отчёт о запуске не записан: #{e.message}"
  end
end

puts "событие #{ev}: обход #{collect ? 'да' : 'нет'}, сборка #{build ? 'да' : 'нет'}#{run_id.empty? ? '' : ", запуск №#{run_id}"}"
File.open(ENV['GITHUB_OUTPUT'] || '/dev/stdout', 'a') do |f|
  f.puts "collect=#{collect}"
  f.puts "build=#{build}"
  f.puts "run_id=#{run_id}"
end
