#!/usr/bin/env ruby
# encoding: utf-8
#
# Сигналы о поломках — в личку Telegram отдельным ботом (не ботом лотов).
#   ruby app/alert.rb tmp/monitor.json   проверка по расписанию (monitor.yml): находки монитора сайта + состояние робота
#   ruby app/alert.rb --event "текст"    разовое событие (упал прогон робота — шаг update.yml при ошибке)
# Секреты GitHub: ALERT_TG_TOKEN — токен бота сигналов; ALERT_TG_CHAT — кому писать (если нет — берём из settings.alert_chat,
# а туда — из первого сообщения боту: достаточно нажать «Start»). База — та же, что у робота (SB_URL, SB_KEY, SB_TOKEN).
# Проблема (fp — отпечаток) присылается, когда появилась; напоминание — раз в 6 часов; «исправлено» — когда пропала.
require 'json'
require 'time'
require 'uri'
require_relative 'sb'

TOKEN = ENV['ALERT_TG_TOKEN'].to_s
REMIND = 6 * 3600
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
  send_text("🔴 БелЛот: #{text}#{RUN_URL ? "\n#{RUN_URL}" : ''}")
  exit 0
end

abort 'нет базы админки (SB_URL, SB_KEY, SB_TOKEN)' unless Sb.on?
now = Time.now
found = []   # [{fp, title, detail}]

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
  age = now - Time.parse(last_c['at'])
  found << { 'fp' => 'robot-stale', 'title' => 'Робот давно не обходил площадки', 'detail' => "последний обход #{(age / 3600).round} ч назад" } if age > 14 * 3600
  found << { 'fp' => 'robot-failed', 'title' => 'Последний обход площадок завершился с ошибкой', 'detail' => 'подробности — в админке, раздел «Сводка»' } if last_c['ok'] == false
  (last_c.dig('stats', 'update', 'unread') || []).each do |src|
    found << { 'fp' => "unread|#{src}", 'title' => "Не читается список площадки: #{src}", 'detail' => 'в последнем обходе — 0 лотов; возможно, площадка сменила вёрстку' }
  end
end
hung = runs.find { |r| r['finished_at'].nil? && now - Time.parse(r['at']) > 90 * 60 && now - Time.parse(r['at']) < 24 * 3600 }
found << { 'fp' => 'robot-hung', 'title' => 'Прогон робота завис', 'detail' => "начат #{Time.parse(hung['at']).getlocal('+03:00').strftime('%d.%m %H:%M')}, отчёта нет" } if hung

# ── Telegram-бот лотов ──
bot = Sb.get('bot_runs?select=at,errors&order=at.desc&limit=1').first
if bot
  age = now - Time.parse(bot['at'])
  found << { 'fp' => 'bot-stale', 'title' => 'Telegram-бот лотов молчит', 'detail' => "последняя проверка площадок #{(age / 3600.0).round(1)} ч назад" } if age > 3 * 3600
  found << { 'fp' => 'bot-errors', 'title' => 'Telegram-бот лотов: часть разделов не прочитана', 'detail' => bot['errors'] } if bot['errors'] && age < 3 * 3600
end

# ── сравнение с тем, что уже отправляли ──
# отметка «отправлено» ставится, только если сообщение ушло: пока бот не подключён, всё копится и придёт первым сообщением
open = Sb.get('alerts?open=eq.true&select=*').map { |a| [a['fp'], a] }.to_h
fresh, remind = [], []
found.each do |p|
  a = open[p['fp']]
  if a.nil? || a['sent_at'].nil? then fresh << p
  elsif now - Time.parse(a['sent_at']) > REMIND then remind << p
  end
end
gone = open.values.reject { |a| found.any? { |p| p['fp'] == a['fp'] } }

# ── ошибки у посетителей: новые с прошлого сообщения ──
cur = (Sb.settings['monitor'] || {})['client_err_id'].to_i
errs = Sb.get("client_errors?id=gt.#{cur}&select=id,at,msg,src,url,ua&order=id&limit=200")
client = errs.group_by { |e| e['msg'] }.first(6).map do |msg, es|
  e = es.first
  dev = e['ua'].to_s =~ /iPhone|iPad/ ? 'iPhone/iPad' : e['ua'].to_s =~ /Android/ ? 'Android' : e['ua'].to_s =~ /Mac OS/ ? 'Mac' : e['ua'].to_s =~ /Windows/ ? 'Windows' : 'браузер'
  "• #{msg.to_s[0, 200]}#{es.size > 1 ? " (×#{es.size})" : ''}\n  #{e['src'].to_s[0, 80]} · #{dev} · #{e['url'].to_s[0, 120]}"
end

# ── сообщение ──
parts = []
parts << "🔴 Новые проблемы:\n#{fresh.map { |p| line(p) }.join("\n")}" unless fresh.empty?
parts << "⏰ Всё ещё не исправлено:\n#{remind.map { |p| line(p) }.join("\n")}" unless remind.empty?
parts << "🟠 Ошибки у посетителей (#{errs.size}):\n#{client.join("\n")}" unless client.empty?
gone_sent = gone.reject { |a| a['sent_at'].nil? }   # о неотправленном «исправлено» не пишем
parts << "✅ Исправлено:\n#{gone_sent.map { |a| "• #{a['title']}" }.join("\n")}" unless gone_sent.empty?
ok = if parts.empty?
       puts "проблем нет (страниц проверено: #{(JSON.parse(File.read(ARGV[0])) rescue {})['checked'] if ARGV[0] && File.exist?(ARGV[0])})"
       false
     else
       send_text("БелЛот — мониторинг\n\n#{parts.join("\n\n")}#{RUN_URL && (fresh.any? || remind.any?) ? "\n\n#{RUN_URL}" : ''}")
     end

# ── запомнить ──
t = now.utc.iso8601
found.each do |p|
  a = open[p['fp']]
  if a.nil?
    Sb.upsert('alerts', [{ 'fp' => p['fp'], 'title' => p['title'], 'detail' => p['detail'], 'open' => true, 'first_at' => t, 'last_at' => t,
                           'sent_at' => ok ? t : nil, 'resolved_at' => nil, 'seen' => 1 }], 'fp')
  else
    upd = { 'last_at' => t, 'detail' => p['detail'], 'title' => p['title'], 'seen' => a['seen'].to_i + 1 }
    upd['sent_at'] = t if ok && (fresh.include?(p) || remind.include?(p))
    Sb.patch('alerts', "fp=eq.#{URI.encode_www_form_component(p['fp'])}", upd)
  end
end
gone.each { |a| Sb.patch('alerts', "fp=eq.#{URI.encode_www_form_component(a['fp'])}", { 'open' => false, 'resolved_at' => t }) }
Sb.upsert('settings', [{ 'k' => 'monitor', 'v' => { 'client_err_id' => errs.last['id'], 'at' => t } }], 'k') if ok && errs.any?
