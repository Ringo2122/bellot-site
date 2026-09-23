#!/usr/bin/env ruby
# encoding: utf-8
# Рыночный ориентир: ищет на Kufar похожие предложения по каждому лоту
# и считает медиану, разброс и число совпадений.
#
# Сопоставление осознанно консервативное: если похожих меньше MIN_N,
# ориентир не показывается вовсе — лучше ничего, чем цифра с потолка.
require 'json'
require 'shellwords'
require 'erb'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

UA    = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
DIR   = File.dirname(File.expand_path(__FILE__))
MIN_N = 3
CAT   = { 'avto' => '2010' }   # легковые авто на Kufar; остальное ищем текстом

def kufar(query, cat)
  # ERB::Util.url_encode, а не Shellwords: кириллицу и пробелы надо кодировать
  # процентами, иначе Kufar игнорирует запрос и отдаёт выдачу по умолчанию.
  url = 'https://api.kufar.by/search-api/v2/search/rendered-paginated?size=40&query=' +
        ERB::Util.url_encode(query)
  url += "&cat=#{cat}" if cat
  raw = `curl -sS --compressed -m 25 -A #{Shellwords.escape(UA)} #{Shellwords.escape(url)} 2>/dev/null`
  JSON.parse(raw.to_s.force_encoding('UTF-8'))
rescue StandardError
  {}
end

# объявление годится, если это продажа, с ценой и его заголовок реально
# содержит слова запроса — иначе в медиану попадает случайный товар
def relevant?(ad, words)
  return false if ad['price_byn'].to_i <= 0
  return false if ad['type'] && ad['type'] != 'sell'   # аренда: цена за сутки/месяц
  cat = (ad['ad_parameters'] || []).find { |p| p['p'] == 'category' }
  cv = (cat && (cat['vl'] || cat['v'])).to_s
  return false if cv =~ /Спрос|Аренд|Услуг|Запчаст|Шины|диски/i
  subj = ad['subject'].to_s.downcase
  words.all? { |w| subj.include?(w.downcase) }
end

# "Volkswagen Caddy, 2009" -> ["Volkswagen Caddy", 2009]
def split_name(name)
  year = name[/\b(19[89]\d|20[0-2]\d)\b/]
  base = name.sub(/,?\s*\b(19[89]\d|20[0-2]\d)\b/, '')
             .gsub(/[«»"']/, ' ').gsub(/\s+/, ' ').strip
  words = base.split(/[\s,]+/).reject { |w| w.length < 2 }
  [words.first(3).join(' '), year&.to_i]
end

# beltorgi пишет в названии всё подряд («Автомобиль легковой универсал BMW X6, 2017 г.в., VIN…»),
# зато марка и год лежат в карточке отдельными строками — берём их
def query_of(l)
  return split_name(l['name']) if l['platform'] == 'e-auction.by'
  rows = (l['details'] || Store.details(l['key'])).flat_map { |s| s['rows'] }
  yr = ((rows.find { |k, _| k =~ /^Год/ } || [])[1].to_s[/\d{4}/] || l['name'][/\b(19[89]\d|20[0-2]\d)\b/])&.to_i
  mark = (rows.find { |k, _| k == 'Марка' } || [])[1]
  # ИПМ: «Легковой седан VOLKSWAGEN PASSAT, 4700 ВР-1 (…)» — марка и модель латиницей
  q = mark ? mark.strip : l['name'][/\b[A-Z][A-Za-z\-]+(?:\s+[A-Za-z0-9\-]+)?/].to_s
  # без года медиана смешает машины разных поколений — такой ориентир хуже, чем никакого
  yr ? [q, yr] : ['', nil]
end

def year_of(ad)
  p = (ad['ad_parameters'] || []).find { |x| x['pl'].to_s =~ /Год/ }
  (p && (p['vl'] || p['v']).to_s[/\d{4}/])&.to_i
end

def median(a)
  s = a.sort
  s.size.odd? ? s[s.size / 2] : ((s[s.size / 2 - 1] + s[s.size / 2]) / 2.0)
end

require_relative 'store'
# Считаем только активные лоты без свежего ориентира: новые и те, что проверялись
# больше REFRESH_DAYS назад. Иначе каждый прогон — сотни запросов к Kufar.
REFRESH_DAYS = 14
NOW = Time.now.to_i
lots = Store.load
found = 0

# "Погрузчик электрический" сравнивать не с чем: такие слова подтягивают
# всю категорию. Нужен опознавательный признак модели — латиница или цифры.
def specific?(query)
  query.split(/\s+/).any? { |w| w =~ /[A-Za-z]{2,}|\d/ }
end

lots.each_with_index do |l, i|
  next if l['section'] == 'nedvizhimost' || l['status'] != 'active'
  next if l['market_at'].to_i > NOW - REFRESH_DAYS * 86_400
  l['market_at'] = NOW
  q, yr = query_of(l)
  next if q.length < 4 || !specific?(q)

  res = kufar(q, CAT[l['section']])
  ads = res['ads'] || []

  key = q.split(/\s+/).first(2)                    # марка и модель должны быть в заголовке
  prices = ads.map do |a|
    next nil unless relevant?(a, key)
    byn = a['price_byn'].to_i / 100.0
    next nil if byn < 100 || byn > 5_000_000
    ay = year_of(a)
    next nil if yr && ay && (ay - yr).abs > 2      # держимся в пределах двух лет
    byn
  end.compact

  if prices.size >= MIN_N
    s = prices.sort
    l['market'] = {
      'median' => median(s).round,
      'low' => s[(s.size * 0.25).floor].round,
      'high' => s[(s.size * 0.75).floor].round,
      'n' => s.size,
      'query' => q,
      'year' => yr,
      'source' => 'kufar.by',
      'link' => 'https://www.kufar.by/l?query=' + q.gsub(' ', '%20')
    }
    found += 1
  end
  STDERR.print "\r#{i + 1}/#{lots.size}, ориентиров #{found}"
  sleep 0.6
end
STDERR.puts

Store.save(lots)
by = Hash.new(0)
lots.each { |l| by[l['section']] += 1 if l['market'] }
STDERR.puts "ориентир найден у #{found} из #{lots.size}: #{by.map { |k, v| "#{k} #{v}" }.join(', ')}"
