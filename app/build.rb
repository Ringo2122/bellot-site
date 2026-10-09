#!/usr/bin/env ruby
# encoding: utf-8
#
# Сборка сайта из памяти (data/) в _site/:
#   index.html  шаблон + короткие записи активных лотов
#   arch.js     свежий архив (закрыт за ARCH_NEW дней) — грузится, только когда посетитель его открыл (календарь, архив)
#   arch2.js    архив старше (архив площадок за год) и строки поиска по нему — когда нужен весь архив
#   det/pN.js   подробности и условия покупки (для калькулятора) — PACKS пачек, у лота пачка постоянная; грузятся на странице лота;
#               там же похожие завершённые торги, история объекта и точка на карте (similar.rb, geo.rb)
#   srch.js     поиск по описанию: VIN, кадастровый и инвентарный номера, адрес, должник — грузится при поиске
#   ph/<id>.jpg фото, по файлу на лот — браузер грузит только те, что на экране
#   admin/      админка
# Страница остаётся лёгкой, сколько бы лотов ни накопилось в архиве.
#
# Решения из админки (база Supabase) накладываются поверх данных площадок:
#   • правки полей — поле, изменённое человеком, робот больше не трогает;
#   • модерация — новый лот с замечаниями (нет фото, цены, города, срок «по правилу», похож на лот
#     другой площадки) не показывается, пока его не одобрят; любой лот можно скрыть или вернуть на проверку;
#   • склейки и разъединения дублей, закрепление на главной, выключенные площадки и разделы,
#     правила калькулятора, тексты.
# После сборки копия каталога с отметками уходит в базу (sync.rb) — по ней работает админка.
require 'json'
require 'base64'
require 'fileutils'
require 'digest'
require 'uri'
require 'zlib'
require_relative 'store'
require_relative 'regions'
require_relative 'sb'
require_relative 'similar'
require_relative 'zones'
require_relative 'bav'
require_relative 'cats'

OUT  = ENV['OUT'] || File.join(Store::ROOT, '_site')
TMP  = File.join(Store::ROOT, 'tmp')
# Пачки подробностей: номер пачки лота постоянный — crc32(id) % PACKS. Раньше пачки шли по порядку лотов и сдвигались
# при каждой сборке: браузер с закэшированной страницей (до 10 минут) искал лот не в той пачке — «подробных сведений нет».
# 02.10: 200 → 1000 — с архивом за год (≈ 28 тыс. лотов) пачка из 200 весила бы 0,7 МБ; в 1000 — ≈ 30 лотов, как было
PACKS = 1000
# свежий архив — arch.js (календарь на главной, недавние лоты), старше — arch2.js
ARCH_NEW = 45
KEEP = %w[id art name price req_to torg url location region debtor area_num platform section
          photo pk market prices status closed why first_seen alt pin result phx land sub].freeze
SECS = %w[nedvizhimost avto gruz spec oborud arenda].freeze

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

def words(s)
  s.to_s.downcase.tr('ё', 'е').scan(/[a-zа-я0-9]{3,}/).uniq
end

# ── решения из админки ──
# Без базы (локальная сборка) — сайт как есть. База настроена, но не ответила — сборку останавливаем:
# иначе на сайт вернулись бы скрытые лоты. Прежняя версия сайта остаётся на месте.
ADM = if Sb.on?
        begin
          { 'cfg' => Sb.settings, 'ov' => Sb.all('overrides').map { |o| [o['key'], o] }.to_h,
            'rules' => Sb.all('dup_rules'), 'photos' => Sb.all('lot_photos', 'key,updated_at'), 'sales' => Sb.all('sales'),
            'news' => Sb.get('news?select=*&published=is.true&order=date.desc,updated_at.desc&limit=500'),
            'media' => Sb.get('site_media?select=id,data&limit=500') }
        rescue StandardError => e
          abort "база админки не ответила — сайт не пересобираю, остаётся прежняя версия: #{e.message}"
        end
      else
        { 'cfg' => {}, 'ov' => {}, 'rules' => [], 'photos' => [], 'sales' => [] }
      end
CFG = ADM['cfg']
OV = ADM['ov']
MOD_SINCE = CFG['mod_since'].to_i   # лоты, появившиеся позже, проходят модерацию; 0 — модерация выключена

now = Time.now.to_i
lots = Store.load
# ссылки со страниц площадок — только http(s): ссылка вида «javascript:…» на сайт не попадёт, даже если площадку взломают
web = ->(u) { u.is_a?(String) && u =~ %r{\Ahttps?://}i ? u : nil }
lots.each do |l|
  l['url'] = web.(l['url'])
  l['phx'] = web.(l['phx']) if l['phx']
  l['pics'] = l['pics'].select { |u| web.(u) } if l['pics'].is_a?(Array)
  l['market'] = l['market'].merge('link' => web.(l['market']['link'])) if l['market'].is_a?(Hash) && l['market']['link']
  # срок истёк после прогона обновления — в выдаче такой лот уже не нужен
  if l['status'] == 'active' && l['req_to'].to_i <= now
    l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
  end
  # konfiskat.by: город есть только в извещении, а часть извещений — сканы. Правило Артёма (24.09):
  # если площадка не указала иного — Минск
  l['location'] = 'г. Минск' if l['platform'] == 'konfiskat.by' && l['location'].to_s.strip.empty?
  # область, а не город: «г. Речица» из старых записей → «Гомельская область» (фильтр «Регион» — только области и Минск)
  l['region'] = region_of(l['location']) unless l['region'].to_s =~ /област|\Aг\. Минск\z/
  l['debtor'] = 'Физическое лицо' if ENV['MASK'] && l['debtor'].to_s =~ FIO
  l['id'] = id_of(l['key'])
  l['photo'] = File.exist?(Store.ph_path(l['key'])) ? l['id'] : nil
  # фильтр «Земельный участок» в «Недвижимости» — участки со всех площадок: сам лот — участок
  # («Производственная база … земельный участок», «Здание … участка связи», «Участок теплиц» — не участки)
  l['land'] = 1 if l['section'] == 'nedvizhimost' && (l['sub_ru'] == 'Земельные участки' || l['name'].to_s =~ /\A\s*земельн\S*\s+участ/i)
  l.delete('prices') unless (l['prices'] || []).size > 1   # показываем только если цена менялась
  # Проверка правдоподобия ориентира: дисконт больше 85% или цена выше рынка втрое —
  # почти всегда промах сопоставления (развалюха за 200 BYN, завод против помещения)
  if (m = l['market'])
    r = m['median'].to_f.positive? ? l['price'].to_f / m['median'] : 0
    l.delete('market') unless r >= 0.15 && r <= 3.0 && m['n'].to_i >= 3
  end
end

# копия для админки — значения площадки, до правок человека
MIRROR = %w[key id art platform section name price req_to torg location region url].freeze
orig = lots.map { |l| [l['key'], MIRROR.map { |k| [k, l[k]] }.to_h] }.to_h

# ── правки человека: его значение главнее площадки ──
descr = {}
ph_src = {}
lots.each do |l|
  o = OV[l['key']] or next
  f = o['fields'] || {}
  %w[name location].each { |k| l[k] = f[k].to_s.strip unless f[k].to_s.strip.empty? }
  l['region'] = region_of(l['location']) unless f['location'].to_s.strip.empty?
  l['section'] = f['section'] if SECS.include?(f['section'])
  l['price'] = f['price'].to_f if f['price'].to_f.positive?
  %w[req_to torg].each { |k| l[k] = f[k].to_i if f[k].to_i.positive? }
  descr[l['key']] = f['descr'].to_s.strip unless f['descr'].to_s.strip.empty?
  if (m = f['market'])
    if m['off']
      l.delete('market')
    elsif m['median'].to_f.positive?
      l['market'] = { 'median' => m['median'].to_f, 'manual' => true, 'note' => m['note'].to_s, 'source' => 'оценка МониТорга' }
    end
  end
  # срок поправлен вручную — статус считаем по нему
  if f['req_to'].to_i.positive?
    if l['req_to'] > now && l['status'] == 'archive' && l['why'] == 'deadline'
      l['status'] = 'active'
      %w[closed why].each { |k| l.delete(k) }
    elsif l['req_to'] <= now && l['status'] == 'active'
      l.merge!('status' => 'archive', 'closed' => l['req_to'], 'why' => 'deadline')
    end
  end
  l['pin'] = 1 if o['pinned'] && l['status'] == 'active'
end

# раздел и подраздел каталога («transport/legkovye») — после правок человека: раздел мог смениться (app/cats.rb)
lots.each { |l| l['sub'] = Cats.of(l, ->(k) { Store.details(k) }) }

# фото, загруженные в админке
FileUtils.mkdir_p(File.join(TMP, 'ph'))
by_key = lots.map { |l| [l['key'], l] }.to_h
ADM['photos'].each do |p|
  l = by_key[p['key']] or next
  row = Sb.get("lot_photos?key=eq.#{URI.encode_www_form_component(p['key'])}&select=data").first or next
  raw = File.join(TMP, 'ph', "#{Digest::MD5.hexdigest(p['key'])}.src")
  dst = File.join(TMP, 'ph', "#{Digest::MD5.hexdigest(p['key'])}.jpg")
  File.binwrite(raw, Base64.decode64(row['data'].to_s.sub(/\Adata:[^,]*,/, '')))
  next warn("фото из админки не обработалось: #{p['key']}") unless Store.shrink(raw, dst)
  ph_src[l['key']] = dst
  l['photo'] = l['id']
end

# ── что не показываем ──
plat_off = (CFG['platforms'] || {}).select { |_, v| v == false }.keys
sec_off = (CFG['sections'] || {}).select { |_, v| v == false }.keys
hidden_why = {}
lots.each do |l|
  hw = if plat_off.include?(l['platform']) then 'plat_off'
       elsif sec_off.include?(l['section']) then 'sec_off'
       elsif (OV[l['key']] || {})['mod'] == 'hidden' then 'hidden'
       end
  hidden_why[l['key']] = hw if hw
end

active = lots.select { |l| l['status'] == 'active' && !hidden_why[l['key']] }.sort_by { |l| l['req_to'].to_i }
arch = lots.select { |l| l['status'] == 'archive' && !hidden_why[l['key']] }.sort_by { |l| -l['closed'].to_i }

# Один лот на нескольких площадках — одна карточка: бывает, что объект выставлен на двух площадках
# с разными датами. Признак дубля — одинаковые название и стартовая цена на РАЗНЫХ площадках
# (на одной площадке это разные лоты). Главная запись — та, где торги раньше; остальные уходят в «alt»:
# площадка, ссылка, сроки. (До 25.09.2026 так склеивались ИПМ и ЦПО; ЦПО больше не собираем.)
# Из админки можно склеить любые два лота вручную (merge) или разъединить ошибочную склейку (split).
sig = lambda do |l|
  l['name'].to_s.downcase.tr('ё', 'е').gsub(/[^a-zа-я0-9]/, '') + '|' + l['price'].to_f.round.to_s
end
when_ = ->(l) { l['torg'] || l['req_to'].to_i + 86_400 }
split_pairs = {}
manual = {}
sigs = active.map { |l| [l['key'], sig.(l)] }.to_h
ADM['rules'].each do |r|
  if r['kind'] == 'split'
    split_pairs[[r['a'], r['b']].sort] = true
    sigs[r['b']] = "k|#{r['b']}" if sigs[r['b']] && sigs[r['a']] == sigs[r['b']]
  end
end
ADM['rules'].each do |r|
  next unless r['kind'] == 'merge' && sigs[r['a']] && sigs[r['b']]
  old = sigs[r['b']]
  sigs.each_key { |k| sigs[k] = sigs[r['a']] if sigs[k] == old }
  manual[sigs[r['a']]] = true
end
dup_of = {}
active.group_by { |l| sigs[l['key']] }.each do |s, g|
  next if g.size < 2
  next if !manual[s] && g.map { |l| l['platform'] }.uniq.size < 2
  main = g.min_by { |l| [when_.(l), l['req_to'].to_i, l['price'].to_f.positive? ? 0 : 1] }
  others = if manual[s]
             g - [main]
           else
             g.reject { |l| l['platform'] == main['platform'] }.group_by { |l| l['platform'] }.map { |_, v| v.min_by(&when_) }
           end
  main['alt'] = ([main] + others).sort_by(&when_).map { |l| { 'platform' => l['platform'], 'url' => l['url'], 'req_to' => l['req_to'], 'torg' => l['torg'] } }
  others.each { |l| dup_of[l['key']] = main['key'] }
end
active.reject! { |l| dup_of[l['key']] }
puts "склеено дублей: #{dup_of.size}" unless dup_of.empty?

# ── модерация ──
# Похожий лот на другой площадке: та же цена и больше половины общих слов в названии, но не склеен
dup_with = {}
active.select { |l| l['price'].to_f.positive? }.group_by { |l| l['price'].to_f.round }.each_value do |g|
  next if g.size < 2 || g.size > 40
  g.combination(2) do |a, b|
    next if a['platform'] == b['platform'] || split_pairs[[a['key'], b['key']].sort]
    wa = words(a['name'])
    wb = words(b['name'])
    next if wa.empty? || wb.empty? || (wa & wb).size.to_f / (wa | wb).size < 0.5
    dup_with[a['key']] ||= b['key']
    dup_with[b['key']] ||= a['key']
  end
end
reasons = {}
active.each do |l|
  r = []
  r << 'no_photo' unless l['photo'] || l['phx'] || l['platform'] == 'mgcn.by'   # МГЦН фото не публикует вовсе — не замечание
  r << 'no_price' unless l['price'].to_f.positive?
  r << 'no_city' if l['location'].to_s.strip.empty?
  # konfiskat: извещение — скан, срок заявок поставлен по правилу организатора
  if l['platform'] == 'konfiskat.by' && Store.details(l['key']).any? { |s| s['rows'].any? { |_, v| v.to_s.include?('по правилу организатора') } }
    r << 'rule_deadline'
  end
  r << 'dup_maybe' if dup_with[l['key']]
  reasons[l['key']] = r
end
queued = 0
active.reject! do |l|
  o = OV[l['key']] || {}
  fresh = MOD_SINCE.positive? && l['first_seen'].to_i > MOD_SINCE
  hold = o['mod'] == 'review' || (fresh && reasons[l['key']].any? && o['mod'] != 'approved')
  next false unless hold
  hidden_why[l['key']] = 'mod'
  # склеенные с ним ждут вместе с ним
  dup_of.each { |k, m| hidden_why[k] = 'dup' if m == l['key'] }
  queued += 1
  true
end
dup_of.each_key { |k| hidden_why[k] ||= 'dup' }
puts "ждут проверки: #{queued}" if queued.positive?

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p([File.join(OUT, 'ph'), File.join(OUT, 'det'), File.join(OUT, 'admin')])

# «Сколько за такие отдают»: похожие завершённые торги и история объекта (similar.rb)
shown = (active + arch).map { |l| [l['key'], l['id']] }.to_h
sim = Similar.run(lots, shown, ADM['sales'], ->(k) { Store.details(k) })
puts "похожие торги: у #{sim.count { |_, v| v['c'] }} лотов, история объекта: у #{sim.count { |_, v| v['h'] }}"

# подробности — пачками с постоянным номером (PACKS): порядок лотов на номер пачки не влияет.
# Фото — каждое отдельным файлом ph/<id>.jpg: странице лота нужно одно фото, а не пачка из 40 (0,6–0,9 МБ)
order = active.group_by { |l| l['section'] }.values.flatten + arch
packs = 0
order.group_by { |l| Zlib.crc32(l['id']) % PACKS }.each do |pk, chunk|
  det = {}
  chunk.each do |l|
    l['pk'] = pk
    secs = Store.details(l['key'])
    if (d = descr[l['key']])
      row = secs.flat_map { |s| s['rows'] }.find { |k, _| k.to_s =~ /\AОписание/i }
      if row
        row[1] = d
      else
        secs.unshift('h' => 'Сведения о лоте', 'rows' => [['Описание', d]])
      end
    end
    x = { 's' => ENV['MASK'] ? mask(secs) : secs, 't' => l['terms'] || {} }
    x.merge!((sim[l['key']] || {}).slice('c', 'h'))
    x['p'] = l['pics'] if (l['pics'] || []).size.positive?   # все фото карточки площадки (ссылками)
    # карта — только у активных; адрес — тот, по которому искали точку (у konfiskat — место хранения)
    if l['status'] == 'active' && l['geo'].is_a?(Array)
      x['g'] = l['geo'] + [l['platform'] == 'konfiskat.by' ? Obj.storage(Obj.rows_of(secs)) : l['location']]
    end
    # «Право аренды»: ставка из извещения; для коэффициента спроса — зона Минска по карте МГЦН (zones.rb)
    x['r'] = l['rent'].merge(l['rent']['k'] == 'ks' ? { 'z' => Zones.at(l['geo']) } : {}) if l['rent']
    det[l['id']] = x
    FileUtils.cp(ph_src[l['key']] || Store.ph_path(l['key']), File.join(OUT, 'ph', "#{l['id']}.jpg")) if l['photo']
  end
  File.write(File.join(OUT, 'det', "p#{pk}.js"), "__det(#{pk},#{JSON.generate(det)});")
  packs += 1
end

# настройки, которые нужны страницам: тексты, правила калькулятора, выключенные разделы, форма заявки
pub = { 'texts' => CFG['texts'] || {}, 'calc' => CFG['calc'] || {}, 'sec_off' => sec_off,
        'bav' => Bav.load.slice('v', 'from', 'src', 'url'),   # действующая БАВ — для расчёта аренды
        'cats' => Cats.tree }                                  # разделы и подразделы каталога
pub['sb'] = { 'url' => ENV['SB_URL'], 'key' => ENV['SB_KEY'] } if Sb.on?
# курс доллара Нацбанка на сегодня: ориентир в долларах под ценой и фильтр по цене в USD. Не ответил — сайт без долларов
def nbrb_usd
  u = URI('https://api.nbrb.by/exrates/rates/USD?parammode=2')
  2.times do
    begin
      j = JSON.parse(Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |h| h.get(u.request_uri).body })
      r = j['Cur_OfficialRate'].to_f / (j['Cur_Scale'] || 1).to_f
      return { 'rate' => r.round(4), 'date' => j['Date'].to_s[0, 10] } if r > 1 && r < 100
    rescue StandardError => e
      warn "курс НБРБ: #{e.class}"
    end
    sleep 3
  end
  nil
end
pub['usd'] = nbrb_usd
# главная из блоков (админка → «Главная страница»): картинки блоков — файлами media/<id>-<отпечаток>.jpg, в настройках —
# пути к ним; ссылки — только http(s) и разделы сайта (#/…). Без настроек сайт собирает главную как раньше.
if CFG['home'].is_a?(Hash)
  media = {}
  if ADM['media']
    FileUtils.mkdir_p(File.join(OUT, 'media'))
    ADM['media'].each do |m|
      next unless m['id'].to_s =~ /\A[\w-]{1,40}\z/
      ext = m['data'].to_s.start_with?('data:image/png') ? 'png' : 'jpg'   # значки и логотип — PNG с прозрачным фоном
      file = "media/#{m['id']}-#{Digest::MD5.hexdigest(m['data'].to_s)[0, 8]}.#{ext}"
      File.binwrite(File.join(OUT, file), Base64.decode64(m['data'].to_s.sub(/\Adata:[^,]*,/, '')))
      media[m['id']] = file
    end
  end
  link = ->(u) { u.to_s.strip =~ %r{\A(https?://|#/)}i ? u.to_s.strip : nil }
  home = JSON.parse(JSON.generate(CFG['home']))
  # картинки: ключи img и logo, наборы imgs (значки разделов и пунктов) — номер картинки → путь к файлу; ссылки — url, btn_url
  fix = lambda do |o|
    case o
    when Array then o.each { |x| fix.(x) }
    when Hash
      o.each_key do |k|
        if %w[img logo].include?(k) then o[k] = media[o[k]]
        elsif k == 'imgs' && o[k].is_a?(Hash) then o[k] = o[k].transform_values { |v| media[v] }.compact
        elsif k == 'imgs' && o[k].is_a?(Array) then o[k] = o[k].map { |v| media[v] }
        elsif %w[url btn_url].include?(k) then o[k] = link.(o[k])
        else fix.(o[k])
        end
      end
    end
  end
  fix.(home)
  pub['home'] = home
end
# новости из админки (без базы — сайт берёт статьи из своего кода). Фото, загруженное в админке, — файлом news/<…>.jpg
# (в имени — отпечаток фото: новое фото не застрянет в кеше браузера); фото по умолчанию — путь к файлу сайта (img/news/…)
if ADM['news']
  FileUtils.mkdir_p(File.join(OUT, 'news'))
  pub['news'] = ADM['news'].map do |n|
    img = n['photo'].to_s
    if img.start_with?('data:')
      file = "news/#{Digest::MD5.hexdigest(n['slug'].to_s)[0, 10]}-#{Digest::MD5.hexdigest(img)[0, 8]}.jpg"
      File.binwrite(File.join(OUT, file), Base64.decode64(img.sub(/\Adata:[^,]*,/, '')))
      img = file
    end
    { 'slug' => n['slug'], 'date' => n['date'], 'title' => n['title'], 'lead' => n['lead'], 'body' => n['body'],
      'img' => (img.empty? ? nil : img), 'src' => n['src'], 'srcName' => n['src_name'],
      'cta' => (n['cta_text'].to_s.strip.empty? || n['cta_url'].to_s.strip.empty? ? nil : [n['cta_text'], n['cta_url']]) }.compact
  end
end

arch_cut = now - ARCH_NEW * 86_400
arch1, arch2 = arch.partition { |l| l['closed'].to_i >= arch_cut }
archn = arch.group_by { |l| l['section'] }.map { |k, v| [k, v.size] }.to_h.merge('_' => arch.size, 'cut' => arch_cut)
# архив по разделам и подразделам каталога — для фильтра «Активные / Архив» до загрузки самого архива
archn['tree'] = arch.each_with_object(Hash.new(0)) { |l, h| next unless l['sub']; h[l['sub']] += 1; h[l['sub'].split('/').first] += 1 }
slim = ->(l) { KEEP.each_with_object({}) { |k, h| h[k] = l[k] unless l[k].nil? }.tap { |h| h['np'] = l['pics'].size if (l['pics'] || []).size > 1 } }
tpl = File.read(File.join(__dir__, 'site.tpl.html'), encoding: 'UTF-8')
html = tpl.sub('__DATA__') { JSON.generate(active.map(&slim)) }
          .sub('__SNAP__', now.to_s).sub('__ARCHN__') { JSON.generate(archn) }
          .sub('__CFG__') { JSON.generate(pub) }
          .sub('__THEME__') { JSON.generate((pub['home'] || {})['theme'] || {}) }   # общий стиль — до отрисовки, без мигания
File.write(File.join(OUT, 'index.html'), html)
File.write(File.join(OUT, 'arch.js'), "__arch(#{JSON.generate(arch1.map(&slim))});")
# поиск по описанию: то, чего нет в карточке, — номера объекта, адрес, марка и модель, начало описания
SRCH_ROWS = /\A(?:Адрес \(местонахождение\)|Местоположение имущества|Местонахождение имущества|Местонахождение|Местоположение|Марка|Модель|Марка \(модель\)|Идентификационный номер|Регистрационный номер|Кадастровый номер|Инвентарный номер.*|Инв\. номер|Год выпуска|Год)\z/
DESC_ROWS = /\A(?:Описание(?: имущества)?|Дополнительная информация(?: по всему лоту)?)\z/
srch = order.map do |l|
  rows = Obj.rows_of(Store.details(l['key']))
  ids = Obj.ids(l['name'], rows).map { |x| x.split(':', 2)[1] }
  desc = rows.select { |k, _| k =~ DESC_ROWS }.map { |_, v| v }.join(' ')[0, l['status'] == 'active' ? 300 : 150]
  # название, место, должник и номер лота поиск берёт из карточки — здесь только то, чего в ней нет
  t = [*rows.select { |k, _| k =~ SRCH_ROWS }.map { |_, v| v }, *ids, *ids.map { |x| x.delete('/-') }, desc].compact.join(' ')
  t = t.gsub(/&#(\d+);/) { $1.to_i.chr('UTF-8') }.downcase.tr('ё', 'е').gsub(/\s+/, ' ').split(' ').uniq.join(' ')
  [l['id'], t] unless t.empty?
end.compact.to_h
# строки поиска старого архива — в arch2.js: srch.js грузится при первом же поиске и должен оставаться лёгким
old = arch2.map { |l| [l['id'], true] }.to_h
srch2 = srch.select { |id, _| old[id] }
srch.reject! { |id, _| old[id] }
File.write(File.join(OUT, 'srch.js'), "__srch(#{JSON.generate(srch)});")
File.write(File.join(OUT, 'arch2.js'), "__arch2(#{JSON.generate(arch2.map(&slim))},#{JSON.generate(srch2)});")
File.write(File.join(OUT, '.nojekyll'), '')
adm = File.read(File.join(__dir__, 'admin.html'), encoding: 'UTF-8')
FileUtils.cp(File.join(__dir__, 'stats.js'), File.join(OUT, 'stats.js'))   # аналитика: общая для админки и кабинета
FileUtils.cp_r(File.join(__dir__, 'noph'), File.join(OUT, 'noph'))   # заглушки «нет фото» по разделам (tools/noph.rb)
FileUtils.cp_r(File.join(__dir__, 'img'), File.join(OUT, 'img'))     # картинки сайта: 3D-значки «Почему МониТорг» (Fluent Emoji, MIT)
File.write(File.join(OUT, 'admin', 'index.html'),
           adm.sub('__SB_URL__') { ENV['SB_URL'].to_s }.sub('__SB_KEY__') { ENV['SB_KEY'].to_s }.sub('__BUILD__', now.to_s))

# копия каталога для админки: значения площадки + отметки сборки (что показано, почему скрыто)
published = active.map { |l| [l['key'], true] }.to_h
mirror = lots.map do |l|
  o = orig[l['key']]
  o.merge('photo' => !l['photo'].nil?, 'status' => l['status'], 'closed' => l['closed'], 'why' => l['why'],
          'first_seen' => l['first_seen'], 'area_num' => l['area_num'], 'debtor' => l['debtor'],
          'price0' => (l['prices'] || []).size > 1 ? l['prices'].first[1] : nil,
          'result' => l['result'] && l['result'].reject { |k, _| %w[checked tries].include?(k) },
          'market' => l['market'] && l['market'].slice('median', 'n', 'source', 'low', 'high', 'manual', 'link'),
          'reasons' => reasons[l['key']] || [], 'dup_with' => dup_with[l['key']], 'dup_of' => dup_of[l['key']],
          'alt' => l['alt'], 'published' => published[l['key']] || (l['status'] == 'archive' && !hidden_why[l['key']]),
          'prev' => l['status'] == 'active' ? (sim[l['key']] || {})['prev'] : nil,   # прошлые торги объекта — для «выставлен снова»
          'hidden_why' => hidden_why[l['key']], 'synced' => now)
end
FileUtils.mkdir_p(TMP)
File.write(File.join(TMP, 'mirror.json'), JSON.generate(mirror))
# итоги завершённых торгов — в постоянную таблицу sales (sync.rb): аналитика продаж копится дольше архива.
# Значения — с правками из админки (раздел, место), включая прошлые торги перевыставленных лотов
FINAL_ST = %w[sold single failed cancelled].freeze
sales = lots.flat_map do |l|
  ([l['result']] + (l['results'] || [])).compact.select { |r| FINAL_ST.include?(r['st']) }.map do |r|
    { 'key' => l['key'], 'at' => (r['at'] || l['closed'] || l['req_to']).to_i, 'id' => l['id'], 'platform' => l['platform'],
      'section' => l['section'], 'region' => l['region'], 'location' => l['location'], 'name' => l['name'], 'debtor' => l['debtor'],
      'area_num' => l['area_num'], 'url' => l['url'], 'st' => r['st'], 'start' => r['start'], 'price' => r['price'],
      'bids' => r['bids'], 'users' => r['users'] }
  end
end.uniq { |x| [x['key'], x['at']] }
File.write(File.join(TMP, 'sales.json'), JSON.generate(sales))
File.write(File.join(TMP, 'build.json'), JSON.generate('published' => active.size, 'queue' => queued, 'merged' => dup_of.size,
                                                        'archive' => arch.size, 'photos' => active.count { |l| l['photo'] }))

by = Hash.new(0)
active.each { |l| by[l['section']] += 1 }
kb = ->(f) { (File.size(File.join(OUT, f)) / 1024.0).round }
puts "активных #{active.size} (#{by.map { |k, v| "#{k} #{v}" }.join(', ')}), в архиве #{arch.size}"
puts "index.html #{kb.('index.html')} КБ, arch.js #{kb.('arch.js')} КБ, arch2.js #{kb.('arch2.js')} КБ, srch.js #{kb.('srch.js')} КБ, пачек #{packs}, " \
     "фото #{order.count { |l| l['photo'] }}, ориентиров #{active.count { |l| l['market'] }}"
