# encoding: utf-8
#
# Карта на странице активного лота: адрес с площадки → координаты. Сервис — OpenStreetMap Nominatim
# (бесплатный; правила: не чаще раза в секунду, понятный User-Agent, кешировать). Кеш — data/geo.json:
# один и тот же адрес или населённый пункт второй раз не спрашиваем.
# Площадки пишут адрес длинно («Брестская область, Пинский р-н, г. Пинск, ул. Рокоссовского, 1») — так
# Nominatim не находит. Спрашиваем от точного к общему: «город, улица, дом» → «город, улица» → «пункт, район, область».
# У лота — geo: [широта, долгота, точность]: a — дом, s — улица, p — населённый пункт.
# konfiskat: адрес торгов — не место машины; берём «На хранении: …» из описания, нет его — карты нет.
require 'json'
require 'uri'
require_relative 'store'
require_relative 'objects'

module Geo
  module_function

  CACHE = File.join(Store::DATA, 'geo.json')
  UA = 'BelLot/1.0 (+https://ringo2122.github.io/bellot-site/)'
  CAP = (ENV['GEO_CAP'] || 900).to_i   # запросов к сервису за прогон
  ST = { 'ул' => 'улица', 'улица' => 'улица', 'пр-т' => 'проспект', 'просп' => 'проспект', 'проспект' => 'проспект', 'пр' => 'проспект',
         'пер' => 'переулок', 'переулок' => 'переулок', 'бул' => 'бульвар', 'б-р' => 'бульвар', 'ш' => 'шоссе', 'шоссе' => 'шоссе',
         'пл' => 'площадь', 'мкр' => 'микрорайон', 'тракт' => 'тракт', 'проезд' => 'проезд', 'пр-д' => 'проезд' }.freeze
  STREET = %r{(?:\A|[\s,])(ул|улица|пр-т|просп|проспект|пр|пер|переулок|бул|б-р|ш|шоссе|пл|мкр|тракт|проезд|пр-д)\.?\s*([^,]+?)(?:,\s*(?:д\.|дом)?\s*(\d+[а-яa-z]?(?:/\d+)?))?\s*(?:,|\z)}i

  def queries(addr)
    a = addr.to_s.tr('ё', 'е').tr('Ё', 'Е').gsub(/\b\d{6}\b,?/, '').strip
    m = a.match(Obj::PLACE)
    town = m ? m[2] : a[/(?<![А-Яа-я])Минск(?![а-я])/] && 'Минск'
    dist = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+(?:р-н|район)/, 1]
    reg = a =~ /обл/ ? region_of(a) : nil   # «Минское шоссе» — не Минская область
    unless town
      # только сельсовет: «Узденский р-н, Слободской с/с, д. 8» — точка по сельсовету
      ss = a[/([А-Я][а-я]+(?:ский|цкий|ской))\s+с\/с/, 1]
      return ss && dist ? ["#{ss} сельский Совет, #{dist} район"] : []
    end
    out = []
    if (s = a.match(STREET))
      name = s[2].strip.sub(/\.\s.*\z/, '')   # «ул. Минское шоссе. УТП «БелшинаТранс»» → «Минское шоссе»
      street = name =~ /(?:шоссе|проспект|переулок|бульвар|тракт|проезд|площадь)\z/i ? name : "#{ST[s[1].downcase]} #{name}"
      out << "#{town}, #{street}, #{s[3]}" if s[3]
      out << "#{town}, #{street}"
    end
    out << [town, dist && "#{dist} район", reg].compact.join(', ')
    out.uniq
  end

  def ask(q)
    u = 'https://nominatim.openstreetmap.org/search?' +
        URI.encode_www_form(format: 'jsonv2', limit: 1, countrycodes: 'by', 'accept-language' => 'ru', q: q)
    out = IO.popen(['curl', '-sS', '-m', '20', '-A', UA, u], err: File::NULL, &:read)
    r = JSON.parse(out.to_s.force_encoding('UTF-8')).first
    return 0 unless r   # 0 — сервис ответил «не нашёл»: запоминаем, чтобы не спрашивать снова
    prec = %w[building house].include?(r['addresstype']) || r['category'] == 'building' ? 'a' : r['addresstype'] == 'road' ? 's' : 'p'
    [r['lat'].to_f.round(5), r['lon'].to_f.round(5), prec]
  rescue JSON::ParserError
    nil   # сбой — не запоминаем
  end

  # активные лоты без координат; stop — когда остановиться (общий бюджет прогона)
  def run(db, stat, stop)
    cache = File.exist?(CACHE) ? (JSON.parse(File.read(CACHE, encoding: 'UTF-8')) rescue {}) : {}
    asked = 0
    todo = db.values.select { |l| l['status'] == 'active' && !l.key?('geo') && l['geo_try'].to_i < 2 }
    todo.each do |l|
      break if asked >= CAP || Time.now > stop
      addr = l['platform'] == 'konfiskat.by' ? Obj.storage(Obj.rows_of(Store.details(l['key']))) : l['location']
      qs = queries(addr)
      if qs.empty?
        l['geo'] = nil
        next
      end
      hit = nil
      failed = false
      qs.each do |q|
        unless cache.key?(q)
          break if asked >= CAP
          r = ask(q)
          asked += 1
          sleep 1.1
          if r.nil?
            failed = true
            break
          end
          cache[q] = r
        end
        (hit = cache[q]) && hit != 0 && break
        hit = nil
      end
      if hit
        l['geo'] = hit
        stat['на карте: найден адрес'] += 1
      elsif failed || !qs.all? { |q| cache.key?(q) }
        l['geo_try'] = l['geo_try'].to_i + 1   # сервис не ответил или вышел лимит — попробуем в следующий раз
      else
        l['geo'] = nil   # сервис такого адреса не знает
        stat['на карте: адрес не найден'] += 1
      end
    end
    File.write(CACHE, JSON.generate(cache))
    STDERR.puts "карта: запросов к OpenStreetMap #{asked}, в кеше #{cache.size}"
  end
end
