#!/usr/bin/env ruby
# encoding: utf-8
#
# Сборка сайта из памяти (data/) в _site/:
#   index.html  шаблон + короткие записи активных лотов
#   arch.js     архив — грузится, только когда посетитель его открыл
#   det/pN.js   подробности и условия покупки (для калькулятора) пачками по 40 — грузятся на странице лота
#   ph/pN.js    фото пачками по 40 — грузятся, когда карточка на экране
# Страница остаётся лёгкой, сколько бы лотов ни накопилось в архиве.
require 'json'
require 'base64'
require 'fileutils'
require 'digest'
require_relative 'store'
require_relative 'regions'

OUT  = ENV['OUT'] || File.join(Store::ROOT, '_site')
PACK = 40
KEEP = %w[id art name price req_to torg url location region debtor area_num platform section
          photo pk market prices status closed why first_seen alt].freeze

# Персональные данные: MASK=1 скрывает ФИО должников-физлиц и контактных лиц по осмотру.
# По умолчанию выключено — решение владельца, вопрос открыт для юриста (закон 99-З).
FIO = /[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\s+(?:[А-ЯЁ][а-яё]+\s+[А-ЯЁ][а-яё]+(?:вич|вна|ична|ич)|[А-ЯЁ]\.\s?[А-ЯЁ]\.)/
PRIVATE = { /Должник|Собственник/ => 'Физическое лицо',
            /Контактное лицо|Мобильный|Ознакомление и осмотр/ => 'Указан на площадке' }.freeze

def mask(secs)
  secs.each do |s|
    s['rows'].each do |row|
      rule = PRIVATE.find { |re, _| row[0] =~ re } or next
      row[1] = rule[1] if row[1].to_s =~ FIO
    end
  end
end

# Адрес страницы лота. У ИПМ ключ — длинный слаг, укорачиваем стабильным хешем.
def id_of(key)
  key.start_with?('ipm-') ? "ipm-#{Digest::MD5.hexdigest(key)[0, 8]}" : key
end

now = Time.now.to_i
lots = Store.load
lots.each do |l|
  # срок истёк после прогона обновления — в выдаче такой лот уже не нужен
  if l['status'] == 'active' && l['req_to'].to_i <= now
    l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
  end
  l['region'] = region_of(l['location']) if l['region'].to_s.empty?
  l['debtor'] = 'Физическое лицо' if ENV['MASK'] && l['debtor'].to_s =~ FIO
  l['id'] = id_of(l['key'])
  l['photo'] = File.exist?(Store.ph_path(l['key'])) ? l['id'] : nil
  l.delete('prices') unless (l['prices'] || []).size > 1   # показываем только если цена менялась
  # Проверка правдоподобия ориентира: дисконт больше 85% или цена выше рынка втрое —
  # почти всегда промах сопоставления (развалюха за 200 BYN, завод против помещения)
  if (m = l['market'])
    r = m['median'].to_f.positive? ? l['price'].to_f / m['median'] : 0
    l.delete('market') unless r >= 0.15 && r <= 3.0 && m['n'].to_i >= 3
  end
end

active = lots.select { |l| l['status'] == 'active' }.sort_by { |l| l['req_to'].to_i }
arch = lots.select { |l| l['status'] == 'archive' }.sort_by { |l| -l['closed'].to_i }

# Один лот на нескольких площадках — одна карточка. ЦПО показывает лоты своих торгов на ИПМ,
# бывает и так, что объект выставлен на двух площадках с разными датами. Признак дубля —
# одинаковые название и стартовая цена на РАЗНЫХ площадках (на одной площадке это разные лоты).
# Главная запись — та, где торги раньше; остальные уходят в «alt»: площадка, ссылка, сроки.
# У ИПМ и ЦПО общий номер лота (12 цифр) — он надёжнее: у лотов в долларах ЦПО не показывает цену в рублях
sig = lambda do |l|
  next "n|#{l['art']}" if %w[ipmtorgi.by cpo.by].include?(l['platform']) && l['art'].to_s =~ /\A\d{9,}\z/
  l['name'].to_s.downcase.tr('ё', 'е').gsub(/[^a-zа-я0-9]/, '') + '|' + l['price'].to_f.round.to_s
end
when_ = ->(l) { l['torg'] || l['req_to'].to_i + 86_400 }
hidden = {}
active.group_by(&sig).each_value do |g|
  next if g.map { |l| l['platform'] }.uniq.size < 2
  # при равных сроках главная — торговая площадка (ИПМ), а не витрина организатора (ЦПО)
  main = g.min_by { |l| [when_.(l), l['req_to'].to_i, l['platform'] == 'cpo.by' ? 1 : 0, l['price'].to_f.positive? ? 0 : 1] }
  others = g.reject { |l| l['platform'] == main['platform'] }.group_by { |l| l['platform'] }.map { |_, v| v.min_by(&when_) }
  main['alt'] = ([main] + others).sort_by(&when_).map { |l| { 'platform' => l['platform'], 'url' => l['url'], 'req_to' => l['req_to'], 'torg' => l['torg'] } }
  others.each { |l| hidden[l['key']] = true }
end
active.reject! { |l| hidden[l['key']] }
puts "склеено дублей: #{hidden.size}" unless hidden.empty?

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p([File.join(OUT, 'ph'), File.join(OUT, 'det')])

# пачки: активные по разделам в порядке показа, затем архив от свежих к старым
order = active.group_by { |l| l['section'] }.values.flatten + arch
packs = 0
order.each_slice(PACK) do |chunk|
  det = {}
  ph = {}
  chunk.each do |l|
    l['pk'] = packs
    secs = Store.details(l['key'])
    det[l['id']] = { 's' => ENV['MASK'] ? mask(secs) : secs, 't' => l['terms'] || {} }
    ph[l['id']] = Base64.strict_encode64(File.binread(Store.ph_path(l['key']))) if l['photo']
  end
  File.write(File.join(OUT, 'det', "p#{packs}.js"), "__det(#{packs},#{JSON.generate(det)});")
  File.write(File.join(OUT, 'ph', "p#{packs}.js"), "__ph(#{packs},#{JSON.generate(ph)});")
  packs += 1
end

archn = arch.group_by { |l| l['section'] }.map { |k, v| [k, v.size] }.to_h.merge('_' => arch.size)
slim = ->(l) { KEEP.each_with_object({}) { |k, h| h[k] = l[k] unless l[k].nil? } }
tpl = File.read(File.join(__dir__, 'site.tpl.html'), encoding: 'UTF-8')
html = tpl.sub('__DATA__') { JSON.generate(active.map(&slim)) }
          .sub('__SNAP__', now.to_s).sub('__ARCHN__') { JSON.generate(archn) }
File.write(File.join(OUT, 'index.html'), html)
File.write(File.join(OUT, 'arch.js'), "__arch(#{JSON.generate(arch.map(&slim))});")
File.write(File.join(OUT, '.nojekyll'), '')

by = Hash.new(0)
active.each { |l| by[l['section']] += 1 }
kb = ->(f) { (File.size(File.join(OUT, f)) / 1024.0).round }
puts "активных #{active.size} (#{by.map { |k, v| "#{k} #{v}" }.join(', ')}), в архиве #{arch.size}"
puts "index.html #{kb.('index.html')} КБ, arch.js #{kb.('arch.js')} КБ, пачек #{packs}, " \
     "фото #{order.count { |l| l['photo'] }}, ориентиров #{active.count { |l| l['market'] }}"
