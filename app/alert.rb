#!/usr/bin/env ruby
# encoding: utf-8
#
# Сигналы о поломках — в личку Telegram отдельным ботом (не ботом лотов).
#   ruby app/alert.rb tmp/monitor.json   проверка по расписанию (monitor.yml): находки монитора сайта + состояние робота
#   ruby app/alert.rb --event "текст"    разовое событие (упал прогон робота — шаг update.yml при ошибке)
# Секреты GitHub: ALERT_TG_TOKEN — токен бота сигналов; ALERT_TG_CHAT — кому писать (если нет — берём из settings.alert_chat,
# а туда — из первого сообщения боту: достаточно нажать «Start»). База — та же, что у робота (SB_URL, SB_KEY, SB_TOKEN).
# Проблема (fp — отпечаток) присылается, когда подтвердилась на двух проверках подряд (разовые сбои не шлём);
# напоминание — раз в 12 часов; «исправлено» — когда пропала (только о том, о чём писали).
require 'json'
require 'time'
require 'uri'
require 'net/http'
require_relative 'sb'

TOKEN = ENV['ALERT_TG_TOKEN'].to_s
REMIND = 12 * 3600
CONFIRM = 20 * 60   # новая проблема ждёт второй проверки (монитор — раз в 30 минут)
RUN_URL = ENV['GITHUB_RUN_ID'] ? "https://github.com/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}" : nil

def tg(method, params)
  return nil if TOKEN.empty?
  out = IO.popen(['curl', '-sS', '-m', '30', '-H', 'Content-Type: application/json', '-d', JSON.generate(params),
                  "https://api.telegram.org/bot#{TOKEN}/#{method}"], err: File::NULL, &:read)
  JSON.parse(out.to_s) rescue nil
end

# кому писать: секрет → настройка → первое сообщение боту («Start»), запоминаем в настройках
def chat_id
  @chat ||= begin
    c = ENV['ALERT_TG_CHAT'].to_s
    c = (Sb.settings['alert_chat'] || {})['id'].to_s if c.empty? && Sb.on?
    if c.empty? && !TOKEN.empty?
      out = IO.popen(['curl', '-sS', '-m', '30', "https://api.telegram.org/bot#{TOKEN}/getUpdates"], err: File::NULL, &:read)
      m = ((JSON.parse(out.to_s) rescue {})['result'] || []).map { |u| u['message'] }.compact.find { |x| x.dig('chat', 'type') == 'private' }
      if m
        c = m['chat']['id'].to_s
        Sb.upsert('settings', [{ 'k' => 'alert_chat', 'v' => { 'id' => c, 'name' => m['chat']['first_name'] } }], 'k') if Sb.on?
      end
    end
    c
  end
end

def send_text(text)
  if TOKEN.empty? || chat_id.empty?
    puts "[сигнал не отправлен — нет бота или чата]\n#{text}"
    return false
  end
  r = tg('sendMessage', { chat_id: chat_id, text: text[0, 4000], disable_web_page_preview: true })
  ok = r && r['ok']
  puts ok ? "отправлено в Telegram:\n#{text}" : "Telegram не принял сообщение: #{r.inspect[0, 200]}"
  ok
end

def line(p)
  "• #{p['title']}" + (p['detail'].to_s.empty? ? '' : "\n  #{p['detail']}")
end

# ── разовое событие ──
if ARGV[0] == '--event'
  text = ARGV[1].to_s
  send_text("🔴 МониТорг: #{text}#{RUN_URL ? "\n#{RUN_URL}" : ''}")
  exit 0
end

abort 'нет базы админки (SB_URL, SB_KEY, SB_TOKEN)' unless Sb.on?
now = Time.now
found = []   # [{fp, title, detail}]

# Запуски GitHub по расписанию. Робот сайта (update.yml) стартует каждые 10 минут, но GitHub иногда часами не запускает
# задания по расписанию — сразу у всех наших: 04.10 почти весь день, 09.10 с 04:23 до 10:41. Тогда и бот лотов молчит,
# и обход опаздывает, но это не поломка: запуски вернутся сами, робот догонит пропущенный обход. Поэтому «бот молчит»
# и «робот не обошёл» — только если GitHub в это время робота запускал (значит, беда именно в нём или в боте).
# nil — GitHub не ответил: тогда судим по-старому.
def sched_runs_since(t)
  repo = ENV['GITHUB_REPOSITORY'] or return nil
  u = "https://api.github.com/repos/#{repo}/actions/workflows/update.yml/runs?event=schedule&per_page=100&created=%3E#{t.utc.iso8601}"
  out = IO.popen(['curl', '-sS', '-m', '30', '-H', "Authorization: Bearer #{ENV['GH_TOKEN']}", '-H', 'Accept: application/vnd.github+json', u], err: File::NULL, &:read)
  runs = (JSON.parse(out.to_s) rescue {})['workflow_runs']
  runs && runs.map { |r| Time.parse(r['created_at']) }
end

# ── находки монитора сайта ──
if ARGV[0] && File.exist?(ARGV[0])
  m = (JSON.parse(File.read(ARGV[0], encoding: 'UTF-8')) rescue nil)
  if m
    found.concat(m['problems'] || [])
  else
    found << { 'fp' => 'monitor-broken', 'title' => 'Монитор сайта не отработал', 'detail' => RUN_URL.to_s }
  end
end

# ── робот ──
runs = Sb.get('runs?select=id,kind,at,finished_at,ok,stats&order=at.desc&limit=30')
last_c = runs.find { |r| r['kind'] == 'collect' && r['finished_at'] }
if last_c
  # обход — по расписанию из админки (часы по Минску). Тревога — если после часа обхода, прошедшего больше 2 ч назад, обхода
  # так и не было. Ночной перерыв между вечерним и утренним обходом — норма (раньше порог «14 ч» срабатывал каждое утро),
  # а GitHub иногда запускает по расписанию с опозданием на час-полтора.
  age = now - Time.parse(last_c['at'])
  hours = Array(Sb.settings['hours']).map(&:to_i).select { |h| h.between?(0, 23) }
  hours = [9, 11, 14, 18] if hours.empty?
  mn = now.getlocal('+03:00')
  due = (0..2).flat_map { |d| day = mn - d * 86_400; hours.map { |h| Time.new(day.year, day.month, day.day, h, 0, 0, '+03:00') } }
             .select { |t| t <= now - 2 * 3600 }.max
  ran = due && sched_runs_since(due + 10 * 60)   # после часа обхода у робота было хотя бы 3 запуска — и всё равно не обошёл
  if due && Time.parse(last_c['at']) < due && (ran.nil? || ran.size >= 3)
    found << { 'fp' => 'robot-stale', 'title' => 'Робот не обошёл площадки по расписанию',
               'detail' => "обхода в #{due.getlocal('+03:00').strftime('%H:%M')} не было; последний — #{(age / 3600).round} ч назад" }
  end
  found << { 'fp' => 'robot-failed', 'title' => 'Последний обход площадок завершился с ошибкой', 'detail' => 'подробности — в админке, раздел «Сводка»' } if last_c['ok'] == false
  # «не читается список» — только если так было два обхода подряд: разовый 0 бывает, когда площадка на минуту
  # недоступна или не ответила роботу GitHub (так было 08.10 с belauction.by — следующий обход прочитал всё)
  prev_c = runs.select { |r| r['kind'] == 'collect' && r['finished_at'] }[1]
  prev_unread = (prev_c && prev_c.dig('stats', 'update', 'unread')) || []
  (last_c.dig('stats', 'update', 'unread') || []).select { |src| prev_unread.include?(src) }.each do |src|
    found << { 'fp' => "unread|#{src}", 'title' => "Не читается список площадки: #{src}", 'detail' => 'два обхода подряд — 0 лотов; возможно, площадка сменила вёрстку или закрыла доступ' }
  end
end
hung = runs.find { |r| r['finished_at'].nil? && now - Time.parse(r['at']) > 90 * 60 && now - Time.parse(r['at']) < 24 * 3600 }
found << { 'fp' => 'robot-hung', 'title' => 'Прогон робота завис', 'detail' => "начат #{Time.parse(hung['at']).getlocal('+03:00').strftime('%d.%m %H:%M')}, отчёта нет" } if hung

# ── Telegram-бот лотов ──
bot = Sb.get('bot_runs?select=at,errors&order=at.desc&limit=1').first
if bot
  age = now - Time.parse(bot['at'])
  # бот запускается каждые 15 минут; «молчит» — когда он не проверял площадки 3 часа, а робот сайта за это время
  # GitHub запускал как обычно (≥ 9 раз, то есть больше полутора часов работы). Новых лотов может не быть по нескольку
  # дней — это не поломка: бот всё равно отмечает каждую проверку.
  if age > 3 * 3600
    ran = sched_runs_since(Time.parse(bot['at']) + 20 * 60)
    if ran.nil? || ran.size >= 9
      found << { 'fp' => 'bot-stale', 'title' => 'Telegram-бот лотов не запускается',
                 'detail' => "последняя проверка площадок #{(age / 3600.0).round(1)} ч назад, хотя робот сайта за это время работал" }
    end
  end
  found << { 'fp' => 'bot-errors', 'title' => 'Telegram-бот лотов: часть разделов не прочитана', 'detail' => bot['errors'] } if bot['errors'] && age < 3 * 3600
end

# ── сравнение с тем, что уже отправляли ──
# отметка «отправлено» ставится, только если сообщение ушло: пока бот не подключён, всё копится и придёт первым сообщением
open = Sb.get('alerts?open=eq.true&select=*').map { |a| [a['fp'], a] }.to_h
fresh, remind = [], []
found.each do |p|
  a = open[p['fp']]
  next if a.nil?                                                     # первая проверка — только запоминаем
  if a['sent_at'].nil? then fresh << p if now - Time.parse(a['first_at']) >= CONFIRM
  elsif now - Time.parse(a['sent_at']) > REMIND then remind << p
  end
end
gone = open.values.reject { |a| found.any? { |p| p['fp'] == a['fp'] } }

# ── ошибки у посетителей: новые с прошлого сообщения ──
mon = Sb.settings['monitor'] || {}
cur = mon['client_err_id'].to_i
errs = Sb.get("client_errors?id=gt.#{cur}&select=id,at,msg,src,url,ua&order=id&limit=200")
# «Не загрузился файл» у посетителя — почти всегда не поломка сайта: блокировщик рекламы, плохая связь или старая копия
# страницы в открытой вкладке (iPhone держит вкладки в памяти и показывает их без перезагрузки — такая страница
# ищет уже переименованные файлы). Поэтому перед сообщением проверяем сам сайт: пишем, только если файл действительно
# не отдаётся (ошибка сервера или 404) И нынешняя версия сайта на него ссылается. Про один файл — не чаще раза в сутки.
# Ошибки в коде сайта — сразу. Всё по-прежнему лежит в базе (client_errors).
file_err = ->(e) { e['src'].to_s.end_with?('файл') }
fsent = (mon['files'] || {}).select { |_, at| now - Time.parse(at) < 86_400 }
site_html = {}
file_broken = lambda do |e|
  path = e['msg'].to_s.sub(/\AНе загрузился файл:\s*/, '').strip.sub(/\?.*\z/, '')
  origin = e['url'].to_s[%r{\Ahttps://[^/]+}] or return false
  u = URI(origin + path)
  code = begin
    Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |h| h.head(u.request_uri).code.to_i }
  rescue StandardError
    0                                                  # сайт не ответил — это поймает проверка страниц монитора
  end
  return false unless code >= 400
  home = e['url'].to_s.sub(/#.*\z/, '')
  site_html[home] ||= (Net::HTTP.get(URI(home)).force_encoding('UTF-8') rescue '')
  site_html[home].include?(File.basename(path))        # старая копия страницы ищет файл, которого в новой нет — не поломка
end
files = errs.select(&file_err).uniq { |e| e['msg'] }.reject { |e| fsent[e['msg']] }.select { |e| file_broken.(e) }.map { |e| e['msg'] }
shown = errs.reject(&file_err) + errs.select { |e| files.include?(e['msg']) }
client = shown.group_by { |e| e['msg'] }.first(6).map do |msg, es|
  e = es.first
  dev = e['ua'].to_s =~ /iPhone|iPad/ ? 'iPhone/iPad' : e['ua'].to_s =~ /Android/ ? 'Android' : e['ua'].to_s =~ /Mac OS/ ? 'Mac' : e['ua'].to_s =~ /Windows/ ? 'Windows' : 'браузер'
  "• #{msg.to_s[0, 200]}#{es.size > 1 ? " (×#{es.size})" : ''}\n  #{e['src'].to_s[0, 80]} · #{dev} · #{e['url'].to_s[0, 120]}"
end

# ── сообщение ──
parts = []
parts << "🔴 Новые проблемы:\n#{fresh.map { |p| line(p) }.join("\n")}" unless fresh.empty?
parts << "⏰ Всё ещё не исправлено:\n#{remind.map { |p| line(p) }.join("\n")}" unless remind.empty?
parts << "🟠 Ошибки у посетителей (#{shown.size}):\n#{client.join("\n")}" unless client.empty?
gone_sent = gone.reject { |a| a['sent_at'].nil? }   # о неотправленном «исправлено» не пишем
parts << "✅ Исправлено:\n#{gone_sent.map { |a| "• #{a['title']}" }.join("\n")}" unless gone_sent.empty?
ok = if parts.empty?
       puts "проблем нет (страниц проверено: #{(JSON.parse(File.read(ARGV[0])) rescue {})['checked'] if ARGV[0] && File.exist?(ARGV[0])})"
       false
     else
       send_text("МониТорг — мониторинг\n\n#{parts.join("\n\n")}#{RUN_URL && (fresh.any? || remind.any?) ? "\n\n#{RUN_URL}" : ''}")
     end

# ── запомнить ──
t = now.utc.iso8601
found.each do |p|
  a = open[p['fp']]
  if a.nil?
    Sb.upsert('alerts', [{ 'fp' => p['fp'], 'title' => p['title'], 'detail' => p['detail'], 'open' => true, 'first_at' => t, 'last_at' => t,
                           'sent_at' => nil, 'resolved_at' => nil, 'seen' => 1 }], 'fp')
  else
    upd = { 'last_at' => t, 'detail' => p['detail'], 'title' => p['title'], 'seen' => a['seen'].to_i + 1 }
    upd['sent_at'] = t if ok && (fresh.include?(p) || remind.include?(p))
    Sb.patch('alerts', "fp=eq.#{URI.encode_www_form_component(p['fp'])}", upd)
  end
end
gone.each { |a| Sb.patch('alerts', "fp=eq.#{URI.encode_www_form_component(a['fp'])}", { 'open' => false, 'resolved_at' => t }) }
# прочитанные ошибки отмечаем и тогда, когда слать было нечего (только одиночные «файлы»); не ушло сообщение — перечитаем
if errs.any? && (ok || parts.empty?)
  fsent.merge!(files.to_h { |m| [m, t] }) if ok
  Sb.upsert('settings', [{ 'k' => 'monitor', 'v' => { 'client_err_id' => errs.last['id'], 'at' => t, 'files' => fsent } }], 'k')
end
