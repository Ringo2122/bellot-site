#!/usr/bin/env ruby
# encoding: utf-8
#
# Обновление памяти сайта: обходит площадки, добавляет новые лоты, обновляет цену и срок у известных,
# отправляет в архив закрытые, собирает итоги торгов и добирает из архивов площадок завершённые торги (backfill.rb).
# Запускается GitHub Actions в 11:00 и 18:00 по Минску; руками — ruby app/update.rb
#
# В архив лот уходит, когда:
#   • срок приёма заявок истёк                         → why: deadline
#   • лот пропал из списка площадки раньше срока        → why: removed
#     (только если список раздела прочитан целиком и не «похудел» подозрительно —
#      иначе сбой площадки отправил бы в архив полкаталога)
# Если лот снова появился в списке (повторные торги) — возвращается из архива.
# Архив хранится RETAIN_DAYS дней, потом лот удаляется вместе с фото.
require_relative 'sources'
require_relative 'regions'
require_relative 'store'
require_relative 'sb'
require_relative 'results'
require_relative 'backfill'
require_relative 'geo'
require_relative 'pics'
require 'fileutils'

RETAIN_DAYS = (ENV['RETAIN_DAYS'] || 180).to_i
MAXV = 800   # длинные значения (порядок оплаты, ответственность) обрезаем
WORKERS = { 'e-auction.by' => 3, 'ipmtorgi.by' => 2, 'beltorgi.by' => 3, 'konfiskat.by' => 1, 'belauction.by' => 1 }.freeze   # belauction: пауза 2 с (Crawl-delay)   # konfiskat.by банит частые запросы
MIN_PRICE = { 'oborud' => 3000 }.freeze   # в оборудовании много мелочи за сотни рублей
# Настройки из админки: выключенные площадки не обходим, минимальная цена по разделам — своя.
# База недоступна — работаем по умолчаниям.
CFG = begin
  Sb.on? ? Sb.settings : {}
rescue StandardError => e
  STDERR.puts "настройки админки не прочитаны: #{e.message}"
  {}
end
PLAT_OFF = (CFG['platforms'] || {}).select { |_, v| v == false }.keys
MINP = MIN_PRICE.merge((CFG['min_price'] || {}).map { |k, v| [k, v.to_f] }.to_h)
# Условия покупки (задаток, шаг, сборы) появились позже самих лотов. У известных лотов без них
# робот дозаполняет их постепенно — не больше TERMS_CAP страниц за прогон, чтобы не нагружать площадки.
TERMS_CAP = (ENV['TERMS_CAP'] || 800).to_i
# e-auction: дата онлайн-торгов есть только в служебном запросе площадки — у известных лотов добираем постепенно
EA_TORG_CAP = (ENV['EA_TORG_CAP'] || 700).to_i
# Итоги торгов: после даты торгов заглядываем на площадку, пока итоги не опубликуют — до 12 раз за 3 недели
RES_CAP = (ENV['RES_CAP'] || 300).to_i

SEC_RU = { 'nedvizhimost' => 'Недвижимость', 'avto' => 'Легковые авто', 'gruz' => 'Грузовые и автобусы',
           'spec' => 'Спецтехника', 'oborud' => 'Оборудование' }.freeze

# площадка → [раздел площадки, раздел сайта; nil — определить по названию]
PLAN = {
  'e-auction.by' => [['/nedvizhimost/', 'nedvizhimost'], ['/legkovye_avtomobili/', 'avto'],
                     ['/gruzovaya_tekhnika_i_avtobusy/', 'gruz'], ['/spetstekhnika/', 'spec'],
                     ['/stanki_i_oborudovanie/', 'oborud']],
  'ipmtorgi.by'  => [['/auctions/nedvizhimost/', 'nedvizhimost'], ['/auctions/transport-i-spetstekhnika/', nil],
                     ['/auctions/stanki-oborudovanie/', 'oborud']],
  'beltorgi.by'  => [['nedvizhimost', 'nedvizhimost'], ['legkovye-avto', 'avto'], ['gruzovye-avto', 'gruz'],
                     ['avtobusy', 'gruz'], ['specztexnika', 'spec'], ['stanki-i-oborudovanie', 'oborud']],
  # konfiskat.by: 'auto' — легковые и грузовые вперемешку, разносим по названию
  'konfiskat.by' => [['avtotransport/auktsiony', 'auto'], ['nedvizhimost/auktsiony', 'nedvizhimost'],
                     ['own-property/auctions', 'oborud']],
  # belauction.by: первые страницы общего списка и категорий (robots.txt), раздел — по категории лота
  'belauction.by' => [['active', nil]]
}.freeze
# Площадки, которые больше не собираем: их лоты удаляются из памяти вместе с подробностями и фото.
# cpo.by (ЦПО) — рекламная витрина торгов ИПМ-Торгов, те же лоты (решение Артёма 25.09.2026)
DROPPED = %w[cpo.by].freeze

# У ИПМ-Торгов транспорт и спецтехника — один раздел; разносим по началу названия
def ipm_kind(name)
  n = name.downcase
  return 'avto' if n.start_with?('легков')
  return 'spec' if n =~ /тракторн|мотоблоч/
  return 'gruz' if n =~ /\A(грузов|автобус|полуприцеп|прицеп|автомобиль\s|автомашина)/
  'spec'
end

# konfiskat.by: автотранспорт одним списком — грузовое узнаём по названию
def kf_kind(name)
  name.downcase =~ /грузов|тягач|самосвал|автобус|прицеп|фургон|рефрижер|бортов|цистерн|\bмаз\b|камаз|\bmaz\b|kamaz|scania|\bdaf\b|\bman\b|iveco|actros|atego|magnum/ ? 'gruz' : 'avto'
end

def list(plat, path)
  case plat
  when 'e-auction.by' then Src.ea_list(path)
  when 'ipmtorgi.by'  then Src.ipm_list(path)
  when 'konfiskat.by' then Src.kf_list(path)
  when 'belauction.by' then Src.ba_list(:active)
  else Src.bt_list(path)
  end
end

def fetch_detail(c)
  html = Src.get(c['url']) or return nil
  d = case c['platform']
      when 'e-auction.by' then Src.ea_detail(html)
      when 'ipmtorgi.by'  then Src.ipm_detail(html)
      when 'konfiskat.by' then Src.kf_detail(html, c)
      when 'belauction.by' then Src.ba_detail(html)
      else Src.bt_detail(html)
      end
  sleep({ 'konfiskat.by' => 1.5, 'belauction.by' => 2 }[c['platform']] || 0.4)
  d
end

def trim(secs)
  secs.map do |s|
    { 'h' => s['h'], 'rows' => s['rows'].map { |k, v| [k, v.length > MAXV ? v[0, MAXV].sub(/\s\S*\z/, '') + '…' : v] } }
  end
end

def new_lot(c, sec, d, src, now)
  plat = c['platform']
  loc = plat == 'ipmtorgi.by' ? c['location'].to_s : d['location'].to_s
  if plat == 'beltorgi.by' && loc !~ /обл|г\.\s*Минск/
    loc = [c['region'], loc].reject { |x| x.to_s.empty? }.join(', ')
  end
  price = c['price'].to_f.positive? ? c['price'] : d['price_byn'].to_f
  { 'key' => c['key'], 'status' => 'active', 'src' => src, 'first_seen' => now, 'last_seen' => now,
    'art' => plat == 'ipmtorgi.by' && !d['lotno'].to_s.empty? ? d['lotno'] : c['art'],
    'name' => plat == 'beltorgi.by' && !d['title'].to_s.empty? ? d['title'] : c['name'],
    'price' => price, 'prices' => [[now, price]],
    # у ИПМ точное время — в карточке лота; у beltorgi в списке его нет вовсе
    'req_to' => plat == 'e-auction.by' ? c['req_to'] : (d['req_to'] || c['req_to']),
    'torg' => d['torg'], 'url' => c['url'], 'location' => loc, 'region' => region_of(loc),
    'debtor' => d['debtor'], 'area_num' => sec == 'nedvizhimost' ? d['area_num'] : nil,
    'sub_ru' => plat == 'e-auction.by' && sec == 'nedvizhimost' ? Src::EA_SUBS[c['sub']] : nil,
    'platform' => plat, 'section' => sec, 'section_ru' => SEC_RU[sec], 'terms' => d['terms'] || {} }
    .tap { |r| r['pics'] = d['photos'] if d['photos'] }   # все фото карточки — ссылками (pics.rb)
end

now = Time.now.to_i
t0 = Time.now
db = Store.load.each_with_object({}) { |l, h| h[l['key']] = l }
dropped = 0
db.delete_if do |k, l|
  next false unless DROPPED.include?(l['platform'])
  [Store.det_path(k), Store.ph_path(k)].each { |x| File.delete(x) if File.exist?(x) }
  dropped += 1
end
before = db.values.count { |l| l['status'] == 'active' }
mx = Mutex.new
seen = {}          # ключи, которые площадки показали в этом прогоне
lists = {}         # src → сколько карточек прочитано (nil — список не прочитан)
stat = Hash.new(0)
pstat = Hash.new { |h, k| h[k] = Hash.new(0) }   # по площадкам — для отчёта в админке
terms_left = TERMS_CAP
ea_torg_left = EA_TORG_CAP
stat['удалено: площадка исключена'] = dropped if dropped.positive?

PLAN.reject { |plat, _| PLAT_OFF.include?(plat) }.map do |plat, secs|
  Thread.new do
    todo = Queue.new
    secs.each do |path, sec|
      src = "#{plat} #{path}"
      cards = list(plat, path)
      mx.synchronize do
        lists[src] = cards.empty? ? nil : cards.size
        cards.each { |c| seen[c['key']] = true }
      end
      STDERR.puts "#{src}: в списке #{cards.size}"
      cards.each do |c|
        next if plat == 'beltorgi.by' && !c['open']          # ещё не принимают заявки
        # у konfiskat в карточке — дата аукциона, заявки закрываются в 12:00 накануне: закрытые не качаем
        next if c['day'] && plat == 'konfiskat.by' && c['day'] - 12 * 3600 < Time.now.to_i
        s = c['sec'] || (sec == 'auto' ? kf_kind(c['name']) : (sec || ipm_kind(c['name'])))   # belauction — раздел из категории лота
        min = MINP[s].to_f
        next if min.positive? && c['price'].to_f.positive? && c['price'] < min
        todo << [c, s, src]
      end
    end
    Array.new(WORKERS[plat]) do
      Thread.new do
        loop do
          c, sec, src = begin
            todo.pop(true)
          rescue ThreadError
            break
          end
          old = mx.synchronize { db[c['key']] }
          if old
            upd = {}
            # beltorgi: с версии 2 в условиях есть аукционный сбор и затраты — пересобираем из подробностей
            if !old.key?('terms') || (c['platform'] == 'beltorgi.by' && old['terms']['v'].to_i < 2)
              go = mx.synchronize { (terms_left -= 1) >= 0 }
              if go
                # у beltorgi условия уже лежат в подробностях — площадку не дёргаем
                if c['platform'] == 'beltorgi.by'
                  upd['terms'] = Src.bt_terms(Store.details(c['key']))
                elsif (d2 = fetch_detail(c))   # площадка не ответила — попробуем в следующий прогон
                  upd['terms'] = d2['terms'] || {}
                end
                mx.synchronize { stat['дозаполнены условия'] += 1 }
              end
            end
            # фото не скачалось — пробуем ещё, не больше трёх прогонов подряд (у части лотов фото нет вовсе)
            if !old['photo'] && old['ph_try'].to_i < 3 && !File.exist?(Store.ph_path(c['key']))
              d3 = fetch_detail(c)
              ok = Store.save_photo([d3 && d3['photo_url'], c['thumb']], c['key'], Src::UA)
              upd['photo'] = ok
              upd['ph_try'] = old['ph_try'].to_i + 1 unless ok
              mx.synchronize { stat[ok ? 'фото докачано' : 'фото не нашлось'] += 1 }
            end
            # konfiskat: извещение не разобралось (нет города и точного срока) — перечитываем, до трёх раз
            if c['platform'] == 'konfiskat.by' && old['location'].to_s.empty? && old['kf_try'].to_i < 3
              d4 = fetch_detail(c)
              if d4 && d4['location']
                upd.merge!('location' => d4['location'], 'region' => region_of(d4['location']), 'req_to' => d4['req_to'], 'torg' => d4['torg'])
                Store.save_details(c['key'], trim(d4['details'] || []))
                mx.synchronize { stat['konfiskat: извещение дочитано'] += 1 }
              else
                upd['kf_try'] = old['kf_try'].to_i + 1
              end
            end
            upd['eid'] = c['eid'] if c['eid'] && !old['eid']
            if c['platform'] == 'e-auction.by' && !old['torg'] && (c['eid'] || old['eid']) && mx.synchronize { (ea_torg_left -= 1) >= 0 }
              t = Res.ea_torg(Res.ea_info(c['eid'] || old['eid']))
              upd['torg'] = t if t
              sleep 0.3
            end
            upd['price'] = c['price'] if c['price'].to_f.positive? && c['price'] != old['price']
            if c['platform'] == 'beltorgi.by'
              # срок по обратному отсчёту разошёлся с известным больше чем на сутки — перевыставили
              if c['est'] && (c['est'] - old['req_to'].to_i).abs > 86_400
                d = fetch_detail(c)
                if d && d['req_to']
                  upd['req_to'] = d['req_to']
                  upd['torg'] = d['torg']
                  upd['terms'] = d['terms'] if d['terms']
                  Store.save_details(c['key'], trim(d['details'] || []))
                end
              end
            elsif c['req_to'].to_i.positive? && c['req_to'] != old['req_to']
              upd['req_to'] = c['req_to']
            end
            mx.synchronize do
              if upd['price']
                (old['prices'] ||= [[old['first_seen'], old['price']]]) << [now, upd['price']]
                stat['цена изменилась'] += 1
              end
              old.merge!(upd)
              old['last_seen'] = now
              if old['status'] == 'archive' && old['req_to'].to_i > now
                old['status'] = 'active'
                (old['results'] ||= []) << old.delete('result') if old['result']   # итоги прошлых торгов — в историю
                old['reopened'] = now
                old.delete('closed')
                old.delete('why')
                stat['вернулись из архива'] += 1
              end
            end
          else
            d = fetch_detail(c) or next
            rec = new_lot(c, sec, d, src, now)
            next unless rec['req_to'].to_i > now
            if plat == 'e-auction.by' && c['eid']
              rec['eid'] = c['eid']
              t = Res.ea_torg(Res.ea_info(c['eid']))
              rec['torg'] = t if t
            end
            rec['tk'] = d['tk'] if d['tk']
            Store.save_details(c['key'], trim(d['details'] || []))
            rec['photo'] = Store.save_photo([d['photo_url'], c['thumb']], c['key'], Src::UA)
            mx.synchronize do
              db[c['key']] = rec
              stat['новых'] += 1
              pstat[plat]['new'] += 1
            end
          end
        end
      end
    end.each(&:join)
  end
end.each(&:join)

# ── архив ──
active_by_src = Hash.new(0)
db.each_value { |l| active_by_src[l['src']] += 1 if l['status'] == 'active' }
db.each_value do |l|
  next unless l['status'] == 'active'
  if l['req_to'].to_i <= now
    l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
    stat['в архив: срок истёк'] += 1
    pstat[l['platform']]['archived'] += 1
  elsif !seen[l['key']] && l['platform'] != 'belauction.by'   # у belauction читаем только первые страницы: пропал из них — ещё не снят
    n = lists[l['src']]
    # список раздела не прочитан или короче половины известного — не верим, ждём следующего прогона
    next if n.nil? || n < active_by_src[l['src']] / 2
    l.merge!('status' => 'archive', 'closed' => now, 'why' => 'removed')
    stat['в архив: снят с площадки'] += 1
    pstat[l['platform']]['archived'] += 1
  end
end

# ── итоги торгов ──
def fetch_result(l)
  case l['platform']
  when 'e-auction.by'
    eid = l['eid'] || ((html = Src.get(l['url'])) && Res.ea_eid(html))
    eid ? [Res.ea_result(Res.ea_info(eid)), { 'eid' => eid }] : [nil, {}]
  when 'ipmtorgi.by'
    html = Src.get(l['url']) or return [nil, {}]
    all = (u = Res.ipm_all_bids_url(html)) && Src.get(u)   # все ставки, а не последние
    [Res.ipm_result(html, all), {}]
  when 'beltorgi.by'
    (html = Src.get(l['url'])) ? [Res.bt_result(html), {}] : [nil, {}]
  when 'konfiskat.by'
    tk = l['tk'] || ((html = Src.get(l['url'])) && Res.kf_tk_url(html))
    return [nil, {}] unless tk
    sleep 1.5
    (html = Src.get(tk)) ? [Res.tk_result(html), { 'tk' => tk }] : [nil, { 'tk' => tk }]
  when 'belauction.by'
    sleep 2
    (html = Src.get(l['url'])) ? [Res.ba_result(html), {}] : [nil, {}]
  else [nil, {}]
  end
rescue StandardError => e
  STDERR.puts "итоги #{l['key']}: ошибка #{e.message}"
  [nil, {}]
end

due = db.values.select do |l|
  next false unless l['status'] == 'archive' && l['why'] == 'deadline'
  r = l['result'] || {}
  next false if (Res::FINAL.include?(r['st']) && r['v'].to_i >= Res::V) || r['tries'].to_i >= 12   # итоги старой версии разбора — перепроверить
  t = l['torg'] || l['req_to'].to_i + 86_400
  t < now - 1800 && t > now - 21 * 86_400
end.sort_by { |l| -(l['torg'] || l['req_to']).to_i }.first(RES_CAP)
STDERR.puts "итоги торгов: проверяю #{due.size}" unless due.empty?
due.group_by { |l| l['platform'] }.map do |plat, ls|
  Thread.new do
    ls.each do |l|
      r, extra = fetch_result(l)
      mx.synchronize do
        l.merge!(extra)
        tries = (l['result'] || {})['tries'].to_i + 1
        l['result'] = (r || l['result'] || { 'st' => 'pending' }).merge('checked' => now, 'tries' => tries)
        if Res::FINAL.include?(l['result']['st'])
          stat["итоги: #{{ 'sold' => 'продан', 'single' => 'продан единственному', 'failed' => 'не состоялись', 'cancelled' => 'отменены' }[l['result']['st']]}"] += 1
          pstat[plat]['results'] += 1
        end
      end
      sleep plat == 'konfiskat.by' ? 1.5 : 0.5
    end
  end
end.each(&:join)

# ── архив площадок: завершённые за месяц торги, которых у нас нет (после итогов — у лотов konfiskat уже есть ссылка на торги) ──
# карта активных лотов — параллельно (другой сервис, свой темп: запрос в секунду)
geo_t = Thread.new do
  Geo.run(db, stat, Time.now + BACK_MIN * 60)
rescue StandardError => e
  STDERR.puts "карта: ошибка #{e.message}"
end
backfill(db, stat, pstat, now)
geo_t.join

# ── все фото карточки у лотов, собранных раньше (у новых — сразу) ──
fill_pics(db, stat)

cut = now - RETAIN_DAYS * 86_400
db.delete_if do |k, l|
  next false unless l['status'] == 'archive' && l['closed'].to_i < cut
  [Store.det_path(k), Store.ph_path(k)].each { |f| File.delete(f) if File.exist?(f) }
  stat['удалено из архива'] += 1
  true
end

Store.save(db.values)
act = db.values.count { |l| l['status'] == 'active' }
# отчёт для админки: что нового по каждой площадке и какие разделы не прочитались
FileUtils.mkdir_p(File.join(Store::ROOT, 'tmp'))
File.write(File.join(Store::ROOT, 'tmp', 'run.json'), JSON.generate(
  'platforms' => pstat, 'stat' => stat, 'unread' => lists.select { |_, n| n.nil? }.keys, 'off' => PLAT_OFF,
  'active_before' => before, 'active' => act, 'archive' => db.size - act, 'minutes' => ((Time.now - t0) / 60).round(1)))
STDERR.puts stat.map { |k, v| "#{k}: #{v}" }.join(', ') unless stat.empty?
STDERR.puts "активных #{before} → #{act}, в архиве #{db.size - act}, за #{((Time.now - t0) / 60).round(1)} мин"
abort('подозрительно мало активных лотов — проверьте парсеры') if act < 100
