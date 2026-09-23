#!/usr/bin/env ruby
# encoding: utf-8
# Рыночный ориентир для недвижимости: сравнение по ТИПУ объекта и ОБЛАСТИ,
# а не по названию — "Свинарник вблизи аг. Синьки" сравнивать не с чем.
# Где у обеих сторон известна площадь, считаем цену за квадратный метр.
require 'json'
require 'shellwords'
require 'erb'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

UA    = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
DIR   = File.dirname(File.expand_path(__FILE__))
MIN_N = 4

# Типы, у которых есть сопоставимый рынок частных объявлений.
# Склады, производства и имущественные комплексы сюда не входят осознанно:
# таких объектов в открытой продаже почти нет, ориентир вышел бы выдуманным.
# term — что ищем, cat_re — какой должна быть КАТЕГОРИЯ объявления на Kufar.
# Без проверки категории текстовый поиск подтягивает дома и коммерцию
# в выборку по гаражам, и медиана уезжает в несколько раз.
TERMS = {
  'Гаражи'                    => ['гараж',       /гараж|стоянк/i],
  'Машиноместа'               => ['машиноместо', /гараж|стоянк|машиномест/i],
  'Дома'                      => ['дом',         /дом|дач|коттедж/i],
  'Земельные участки'         => ['участок',     /участ|земл/i],
  'Квартиры и комнаты'        => ['квартира',    /квартир|комнат/i],
  'Коммерческая недвижимость' => ['помещение',   /коммерч|офис|торгов|производствен|склад/i]
}.freeze

def kufar(query)
  url = 'https://api.kufar.by/search-api/v2/search/rendered-paginated?size=60&query=' +
        ERB::Util.url_encode(query)
  raw = `curl -sS --compressed -m 25 -A #{Shellwords.escape(UA)} #{Shellwords.escape(url)} 2>/dev/null`
  JSON.parse(raw.to_s.force_encoding('UTF-8'))
rescue StandardError
  {}
end

def par(ad, re)
  p = (ad['ad_parameters'] || []).find { |x| x['pl'].to_s =~ re }
  p && (p['vl'] || p['v']).to_s
end

def median(a)
  s = a.sort
  s.size.odd? ? s[s.size / 2] : ((s[s.size / 2 - 1] + s[s.size / 2]) / 2.0)
end

require_relative 'regions'
require_relative 'store'
# Считаем только активные лоты без свежего ориентира: новые и те, что проверялись
# больше REFRESH_DAYS назад. Иначе каждый прогон — сотни запросов к Kufar.
REFRESH_DAYS = 14
NOW = Time.now.to_i
lots = Store.load
found = 0
skipped = 0

# Здания, цеха и комплексы с рядовыми объявлениями не сравниваем: «здание гаражей
# на 2000 м²» не одиночный гараж, а производственное помещение не офис.
def kind_of(name)
  n = name.to_s.downcase
  return nil if n =~ /здани|комплекс|цех|производств|склад|строени|сооружени/
  return nil if n =~ /аренд|(?<![а-яё])дол[яиейю](?![а-яё])/   # право аренды и доли — не сам объект
  return 'Квартиры и комнаты' if n =~ /квартир|комнат/
  return 'Машиноместа' if n =~ /машино-?мест/
  return 'Гаражи' if n =~ /\Aгараж|гаражн\S* бокс/
  return 'Земельные участки' if n =~ /\Aземельн/
  return 'Дома' if n =~ /жило[йго]+ дом|садов|дач|коттедж/
  return 'Коммерческая недвижимость' if n =~ /помещени|офис|магазин/
  nil
end

lots.each_with_index do |l, i|
  next unless l['section'] == 'nedvizhimost' && l['status'] == 'active'
  next if l['market_at'].to_i > NOW - REFRESH_DAYS * 86_400
  l['market_at'] = NOW
  spec = TERMS[l['sub_ru'] || kind_of(l['name'])]
  region = (l['region'].to_s.empty? ? region_of(l['location']) : l['region']).to_s
  if spec.nil? || region.empty?
    skipped += 1
    next
  end
  term, cat_re = spec

  ads = (kufar("#{term} #{region}")['ads'] || []).select do |a|
    next false if a['price_byn'].to_i <= 0
    next false if a['type'] && a['type'] != 'sell'   # аренда в той же категории, цена за месяц
    cat = par(a, /Категория/).to_s
    next false if cat =~ /Спрос|Аренд|Услуг/i
    next false unless cat =~ cat_re            # категория должна совпасть с типом лота
    ar = par(a, /Область|Регион/).to_s
    ar.empty? || ar.split(/\s/).first.to_s[0, 6] == region.split(/\s/).first.to_s[0, 6]
  end

  prices = ads.map { |a| a['price_byn'].to_i / 100.0 }.select { |p| p > 300 && p < 3_000_000 }
  # цена за м² — считаем только если площадь есть и у лота, и у объявлений
  sqm = ads.map do |a|
    s = par(a, /[Пп]лощадь/).to_s.tr(',', '.')[/\d+(\.\d+)?/]&.to_f
    p = a['price_byn'].to_i / 100.0
    (s && s > 5 && p > 300) ? (p / s) : nil
  end.compact

  next if prices.size < MIN_N

  s = prices.sort
  m = { 'median' => median(s).round, 'low' => s[(s.size * 0.25).floor].round,
        'high' => s[(s.size * 0.75).floor].round, 'n' => s.size,
        'query' => "#{term}, #{region}", 'source' => 'kufar.by',
        'link' => 'https://www.kufar.by/l?query=' + ERB::Util.url_encode("#{term} #{region}") }
  if sqm.size >= MIN_N && l['area_num'].to_f > 5
    m['sqm'] = median(sqm.sort).round
    m['sqm_n'] = sqm.size
    m['lot_sqm'] = (l['price'].to_f / l['area_num'].to_f).round
  end
  l['market'] = m
  found += 1
  STDERR.print "\r#{i + 1}/#{lots.size}, ориентиров #{found}"
  sleep 0.6
end
STDERR.puts

Store.save(lots)
STDERR.puts "недвижимость: ориентир у #{found}, пропущено по типу #{skipped}"
