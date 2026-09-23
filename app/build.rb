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
          photo pk market prices status closed why first_seen].freeze

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
