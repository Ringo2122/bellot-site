#!/usr/bin/env ruby
# encoding: utf-8
#
# Обновление памяти сайта: обходит три площадки, добавляет новые лоты,
# обновляет цену и срок у известных, отправляет в архив закрытые.
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

RETAIN_DAYS = (ENV['RETAIN_DAYS'] || 180).to_i
MAXV = 800   # длинные значения (порядок оплаты, ответственность) обрезаем
WORKERS = { 'e-auction.by' => 3, 'ipmtorgi.by' => 2, 'beltorgi.by' => 3, 'cpo.by' => 2, 'konfiskat.by' => 1 }.freeze   # konfiskat.by банит частые запросы
MIN_PRICE = { 'oborud' => 3000 }.freeze   # в оборудовании много мелочи за сотни рублей
# Условия покупки (задаток, шаг, сборы) появились позже самих лотов. У известных лотов без них
# робот дозаполняет их постепенно — не больше TERMS_CAP страниц за прогон, чтобы не нагружать площадки.
TERMS_CAP = (ENV['TERMS_CAP'] || 800).to_i

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
  # ЦПО — сайт организатора торгов на ИПМ: лоты почти все те же, склеиваются при сборке сайта (build.rb)
  'cpo.by'       => [['nedvizhimost', 'nedvizhimost'], ['transport-i-spetstekhnika', nil], ['stanki-oborudovanie', 'oborud']],
  # konfiskat.by: 'auto' — легковые и грузовые вперемешку, разносим по названию
  'konfiskat.by' => [['avtotransport/auktsiony', 'auto'], ['nedvizhimost/auktsiony', 'nedvizhimost'],
                     ['own-property/auctions', 'oborud']]
}.freeze

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
  when 'cpo.by'       then Src.cpo_list(path)
  when 'konfiskat.by' then Src.kf_list(path)
  else Src.bt_list(path)
  end
end

def fetch_detail(c)
  html = Src.get(c['url']) or return nil
  d = case c['platform']
      when 'e-auction.by' then Src.ea_detail(html)
      when 'ipmtorgi.by'  then Src.ipm_detail(html)
      when 'cpo.by'       then Src.ipm_detail(html, Src::CPO)
      when 'konfiskat.by' then Src.kf_detail(html, c)
      else Src.bt_detail(html)
      end
  sleep c['platform'] == 'konfiskat.by' ? 1.5 : 0.4
  d
end

def trim(secs)
  secs.map do |s|
    { 'h' => s['h'], 'rows' => s['rows'].map { |k, v| [k, v.length > MAXV ? v[0, MAXV].sub(/\s\S*\z/, '') + '…' : v] } }
  end
end

def new_lot(c, sec, d, src, now)
  plat = c['platform']
  loc = %w[ipmtorgi.by cpo.by].include?(plat) ? c['location'].to_s : d['location'].to_s
  if plat == 'beltorgi.by' && loc !~ /обл|г\.\s*Минск/
    loc = [c['region'], loc].reject { |x| x.to_s.empty? }.join(', ')
  end
  price = c['price'].to_f.positive? ? c['price'] : d['price_byn'].to_f
  { 'key' => c['key'], 'status' => 'active', 'src' => src, 'first_seen' => now, 'last_seen' => now,
    'art' => %w[ipmtorgi.by cpo.by].include?(plat) && !d['lotno'].to_s.empty? ? d['lotno'] : c['art'],
    'name' => plat == 'beltorgi.by' && !d['title'].to_s.empty? ? d['title'] : c['name'],
    'price' => price, 'prices' => [[now, price]],
    # у ИПМ точное время — в карточке лота; у beltorgi в списке его нет вовсе
    'req_to' => plat == 'e-auction.by' ? c['req_to'] : (d['req_to'] || c['req_to']),
    'torg' => d['torg'], 'url' => c['url'], 'location' => loc, 'region' => region_of(loc),
    'debtor' => d['debtor'], 'area_num' => sec == 'nedvizhimost' ? d['area_num'] : nil,
    'sub_ru' => plat == 'e-auction.by' && sec == 'nedvizhimost' ? Src::EA_SUBS[c['sub']] : nil,
    'platform' => plat, 'section' => sec, 'section_ru' => SEC_RU[sec], 'terms' => d['terms'] || {} }
end

now = Time.now.to_i
t0 = Time.now
db = Store.load.each_with_object({}) { |l, h| h[l['key']] = l }
before = db.values.count { |l| l['status'] == 'active' }
mx = Mutex.new
seen = {}          # ключи, которые площадки показали в этом прогоне
lists = {}         # src → сколько карточек прочитано (nil — список не прочитан)
stat = Hash.new(0)
terms_left = TERMS_CAP

PLAN.map do |plat, secs|
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
        s = sec == 'auto' ? kf_kind(c['name']) : (sec || ipm_kind(c['name']))
        min = MIN_PRICE[s]
        next if min && c['price'].to_f.positive? && c['price'] < min
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
            Store.save_details(c['key'], trim(d['details'] || []))
            rec['photo'] = Store.save_photo([d['photo_url'], c['thumb']], c['key'], Src::UA)
            mx.synchronize do
              db[c['key']] = rec
              stat['новых'] += 1
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
  elsif !seen[l['key']]
    n = lists[l['src']]
    # список раздела не прочитан или короче половины известного — не верим, ждём следующего прогона
    next if n.nil? || n < active_by_src[l['src']] / 2
    l.merge!('status' => 'archive', 'closed' => now, 'why' => 'removed')
    stat['в архив: снят с площадки'] += 1
  end
end

cut = now - RETAIN_DAYS * 86_400
db.delete_if do |k, l|
  next false unless l['status'] == 'archive' && l['closed'].to_i < cut
  [Store.det_path(k), Store.ph_path(k)].each { |f| File.delete(f) if File.exist?(f) }
  stat['удалено из архива'] += 1
  true
end

Store.save(db.values)
act = db.values.count { |l| l['status'] == 'active' }
STDERR.puts stat.map { |k, v| "#{k}: #{v}" }.join(', ') unless stat.empty?
STDERR.puts "активных #{before} → #{act}, в архиве #{db.size - act}, за #{((Time.now - t0) / 60).round(1)} мин"
abort('подозрительно мало активных лотов — проверьте парсеры') if act < 100
