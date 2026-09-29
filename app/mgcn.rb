# encoding: utf-8
#
# mgcn.by — очные аукционы государственного предприятия «МГЦН» (г. Минск, ул. К. Маркса, 39, зал аукционов).
# Аукцион — пост с таблицей; строка таблицы — предмет аукциона, у нас — отдельная карточка. Разделы сайта МГЦН:
#   /auctions/rent/   право аренды помещений и открытых площадок          → «Право аренды»
#   /auctions/place/  земельные участки: в аренду (№ …-А-…, …-У-…)          → «Право аренды»,
#                     в собственность (по тексту поста)                     → «Недвижимость»
#   /auctions/sale/   квартиры, машино-места, помещения                      → «Недвижимость»;
#                     электронные торги этого раздела идут на minskestate.by — берём их там
# Список раздела — одна страница со всеми постами с 2024 года; прошедшие помечены «завершен» — их не открываем.
# Итогов онлайн нет: после аукциона лот уходит в архив с пометкой «итоги не публикуются».
# Таблицы у постов разные — колонки узнаём по словам в заголовке (COLS); объединённые ячейки разворачиваем.
# Ставка аренды («коэффициент спроса … или размер арендной платы в БАВ») разбирается в rent — расчёт на сайте.
require_relative 'sources'

module Mg
  BASE = 'https://mgcn.by'
  PARTS = %w[rent place sale].freeze
  # порядок важен: «Начальная цена права … / сумма задатка» — цена; «Наименование, характеристики и местонахождение» — описание
  COLS = [['price', /начальная цена/i], ['deposit', /задат/i], ['rate', /коэффициент спроса|арендной платы/i],
          ['no', /\A№|номер предмета/i], ['lessor', /\Aарендодатель/i], ['kad', /кадастров/i], ['period', /период функцион/i],
          ['purpose', /целев/i], ['form', /форма объекта/i], ['term', /срок аренды/i], ['costs', /расходы на подготовку/i],
          ['objects', /краткая информация/i], ['losses', /убытк/i], ['desc', /наименование|характеристик/i],
          ['addr', /местонахожден|месторасположен/i], ['area', /\Aплощадь/i]].freeze
  MON = %w[января февраля марта апреля мая июня июля августа сентября октября ноября декабря].freeze

  module_function

  def date(s, h = 12, m = 0)
    s = s.to_s.gsub(/\s+/, ' ')
    if (x = s.match(/(\d{1,2}) ([а-я]+) (\d{4})/)) && (mon = MON.index(x[2]))
      Time.local(x[3].to_i, mon + 1, x[1].to_i, h, m).to_i
    elsif (x = s.match(/(\d{1,2})\.\s?(\d{2})\.(\d{4})/))
      Time.local(x[3].to_i, x[2].to_i, x[1].to_i, h, m).to_i
    end
  end

  # предстоящие посты раздела: [url, заголовок]
  def posts(part)
    html = Src.get("#{BASE}/auctions/#{part}/") or return nil
    html.split('w-auction-list__item').drop(1).reject { |x| x =~ /завершен/ }.map do |x|
      u = x[%r{href="(https://mgcn\.by/auction/[^"]+)"}, 1] or next
      [u, Src.txt(x[%r{<b>(.*?)</b>}m, 1])]
    end.compact
  end

  # таблица → строки ячеек; rowspan/colspan разворачиваем
  def grid(tb)
    span = {}
    tb.scan(%r{<tr[^>]*>(.*?)</tr>}m).map do |(tr)|
      row = []
      fill = -> { while (s = span[row.size]) && s[0].positive?; s[0] -= 1; row << s[1]; end }
      tr.scan(%r{<t[dh]([^>]*)>(.*?)</t[dh]>}m).each do |attrs, h|
        fill.()
        t = Src.txt(h)
        rs = attrs[/rowspan="?(\d+)/, 1].to_i
        [attrs[/colspan="?(\d+)/, 1].to_i, 1].max.times { span[row.size] = [rs - 1, t] if rs > 1; row << t }
      end
      fill.()
      row
    end
  end

  def num(s)
    Src.num(s.to_s[/\d[\d\s]*(?:[.,]\d+)?/])
  end

  def fmt(x)
    x.to_f.round(4).to_s.sub(/\.0\z/, '').tr('.', ',')
  end

  # «0,8 — первых 3 месяца; 1,5 — последующий период; 3 — при применении понижающих коэффициентов»,
  # «2,5 — 1-й этаж, антресоль; 0,5 — подвал», «220,815 БАВ», «3 (386,55 БАВ за всю площадь)», «1,5 БАВ за 1 кв. м»,
  # «за март, октябрь, ноябрь – 3 БАВ; за апрель–сентябрь – 4 БАВ» (в месяц за 1 кв. м)
  def rent(cell, head, area)
    t = cell.to_s.tr('–−', '——').gsub(/\s+/, ' ').strip
    return nil if t.empty?
    n = ->(s) { s.tr(',', '.').to_f }
    return { 'k' => 'raw', 'raw' => t } if t =~ /\d\s*[х*×]\s*\d/   # «4,0 х 0,6», «0,5*3» — не по формуле, показываем как есть
    if t =~ /БАВ/
      if head =~ /за 1 кв/i || t =~ /за 1 кв/i
        # «за март, октябрь, ноябрь — 3 БАВ; за апрель—сентябрь — 4 БАВ», «В весенне-осенний период 3 БАВ за 1 кв. м, в период … 0,5 БАВ»
        parts = t.gsub(/\s*за\s+1\s*кв\.?\s*м\.?/i, '').split(/;\s*|,\s*(?=(?:в|за)\s)/i).map do |seg|
          m = seg.match(/\A(.*?)\s*—?\s*(\d+(?:,\d+)?)\s*БАВ/) or next
          { 'v' => n.(m[2]), 'what' => m[1].sub(/\A[\s,]*(?:за|в)\s+/i, '').strip }
        end.compact
        return { 'k' => 'bav_m2', 'S' => area, 'parts' => parts, 'raw' => t } unless parts.empty?
      elsif (v = t[/(\d+(?:,\d+)?)\s*БАВ/, 1])
        return { 'k' => 'bav_total', 'v' => n.(v), 'raw' => t }
      end
      return { 'k' => 'raw', 'raw' => t }
    end
    spec = { 'k' => 'ks', 'S' => area, 'steps' => [], 'parts' => [], 'raw' => t }
    # «2,5 — 1-й этаж, 0,5 — подвал»: части бывают и через запятую; «2,5; (3 — при применении …)» — скобки вокруг части
    t.split(/;\s*|,\s+(?=\d+(?:,\d+)?\s*[—-])/).map { |s| s.strip.sub(/\A\((.*)\)\z/, '\1') }.reject(&:empty?).each do |seg|
      m = seg.match(/\A(\d+(?:,\d+)?)\s*(?:—|-)?\s*(.*)\z/) or return { 'k' => 'raw', 'raw' => t }
      ks = n.(m[1])
      w = m[2].to_s.strip
      if w =~ /понижающ/i then spec['alt'] = ks
      elsif w =~ /этаж|подвал|цокол|антресол|мансард/i
        s = w[/\(([\d,]+)\s*кв/, 1]
        spec['parts'] << { 'ks' => ks, 'what' => w.sub(/\s*\([^)]*\)\s*\z/, '').strip, 'S' => s && n.(s) }.compact
      elsif (mo = w[/(\d+|одн\S+|двух|два|тр[её]х|три|шести|шесть)\s*(?:первых\s*)?месяц/i, 1] || (w =~ /первы\S* месяц/ ? '1' : nil))
        words = { 'одн' => 1, 'два' => 2, 'двух' => 2, 'три' => 3, 'трех' => 3, 'трёх' => 3, 'шесть' => 6, 'шести' => 6 }
        spec['steps'] << { 'ks' => ks, 'm' => mo =~ /\d/ ? mo.to_i : words.find { |k, _| mo.downcase.start_with?(k) }&.last }
      else
        spec['steps'] << { 'ks' => ks }
      end
    end
    spec['steps'].empty? && spec['parts'].empty? ? { 'k' => 'raw', 'raw' => t } : spec
  end

  # заголовок таблицы: строка, где узнаются цена и ещё хотя бы две колонки
  def columns(row)
    cols = {}
    row.each_with_index do |h, i|
      k = (COLS.find { |_, re| h =~ re } || [])[0] or next
      # несколько колонок цены (квартира, машино-место, предмет) — ценой считаем цену предмета
      cols[k] = i if !cols[k] || (k == 'price' && h =~ /предмет/i)
    end
    cols['price'] && cols.size >= 3 ? cols : nil
  end

  # имя карточки по строке таблицы; term — срок аренды земли
  def name_of(sec, land, v, area_m2, hdr, term, build)
    d = v['desc'].to_s
    if land
      "Земельный участок #{fmt(num(v['area']))} га" + (build ? ' под строительство' : '') +
        (sec == 'arenda' ? " в аренду#{term ? " на #{term}" : ''}" : '')
    elsif sec == 'arenda'
      base = if hdr =~ /открыт\S* площадк/i || v['form'] then "Открытая площадка#{v['form'] ? " (#{v['form']})" : ''}"
             else d.split(/\s+[—-]\s+|\.\s/).first.to_s.gsub(/\s*\([^)]*\)?/, '').strip.sub(/\A(.)/) { $1.upcase }
             end
      base = 'Помещение' if base.empty? || base.size > 70
      area_m2 ? "#{base}, #{fmt(area_m2)} м²" : base
    else
      rooms = d[/число комнат\s*[—-]\s*(\d+)/, 1]
      kind = if d =~ /квартир/i then rooms ? "#{rooms}-комнатная квартира" : 'Квартира'
             elsif d =~ /\Aмашино-мест/i then 'Машино-место'
             else d.split(/,|\.\s/).first.to_s.strip.sub(/\A(.)/) { $1.upcase }
             end
      kind = 'Помещение' if kind.empty? || kind.size > 60
      kind += ' с машино-местом' if d =~ /квартир/i && d =~ /машино-мест/i
      area_m2 ? "#{kind}, #{fmt(area_m2)} м²" : kind
    end
  end

  # предметы одного поста → карточки для update.rb (подробности уже внутри — страницу второй раз не открываем)
  def items(url, title, part, html)
    main = html[%r{<main.*</main>}m].to_s.tr(" ", ' ')   # неразрывные пробелы в суммах: «652 349,28»
    t = Src.txt(main)
    id = html[/postid-(\d+)/, 1] or return []
    # электронные торги раздела «в собственность» — на minskestate.by
    return [] if part == 'sale' && (title =~ /электронн/i || main !~ /<table/)
    land = part == 'place'
    sec = case part
          when 'rent' then 'arenda'
          when 'sale' then 'nedvizhimost'
          else "#{title} #{t[0, 1500]}" =~ /в\s+(?:частную\s+)?собственность|по продаже[^.]{0,160}земельн/i ? 'nedvizhimost' : 'arenda'
          end
    no = title[/(\d+)-й открытый аукцион/, 1] || title[/№\s*([\dА-ЯA-Z]+-[А-ЯA-Z]+-\d+)/, 1]
    tm = t.match(/(?:Аукцион|Торги)\s+(?:состоится|проводится|проводятся)\s+(\d{1,2}\s+[а-я]+\s+\d{4})\s*(?:г\.|года)?\s*в\s*(\d{1,2})[.:](\d{2})/)
    torg = tm && date(tm[1], tm[2].to_i, tm[3].to_i)
    seg = t[/(?:Прием|Приём)\s+(?:документов|заявлений).{0,700}/m].to_s
    dl = seg[/\bпо\s+(\d{1,2}\s+[а-я]+\s+\d{4}|\d{1,2}\.\s?\d{2}\.\d{4})/, 1]
    req = nil
    if dl
      day = Time.at(date(dl))
      fri = seg.match(/по пятницам\s*[—–−-]?\s*до\s*(\d{1,2})[.:](\d{2})/)
      last = seg[/\A.*?(?=\(по пятницам|\z)/m].scan(/до\s*(\d{1,2})[.:](\d{2})/).last || %w[17 00]
      hm = day.friday? && fri ? [fri[1], fri[2]] : last
      req = Time.local(day.year, day.month, day.day, hm[0].to_i, hm[1].to_i).to_i
    end
    place = t[/(?:состоится|проводится|проводятся)\s+\d{1,2}\s+[а-я]+\s+\d{4}.{0,30}?по адресу:\s*(.{10,90}?\bкаб\.\s*\d+(?:\s*\(зал аукционов\))?)/, 1]
    term = t[/Договор аренды заключается сроком на ([^,.]+)/, 1]
    lessor0 = t[/Арендодател[ья]\s*[—–−-]\s*(.{5,160}?)(?:(?<!тел)\.\s|;\s|\z)/, 1]
    bav = t.match(/базовая арендная величина \(БАВ\) с (\d{2}\.\d{2}\.\d{4}) составляет (\d+),(\d{2})/)
    cond = [['Формат торгов', 'Очный аукцион — участники присутствуют в зале, итоги онлайн не публикуются'],
            ['Аукцион', [no && "№ #{no}", torg && Time.at(torg).strftime('%d.%m.%Y %H:%M')].compact.join(', ')],
            ['Место проведения', place || 'г. Минск, ул. К. Маркса, 39, зал аукционов'],
            ['Приём документов', req && "до #{Time.at(req).strftime('%d.%m.%Y %H:%M')}, г. Минск, ул. К. Маркса, 39"],
            ['Срок договора аренды', sec == 'arenda' && !land ? (term ? "#{term}, если в описании предмета не указано иное" : nil) : nil],
            ['Базовая арендная величина', bav && "#{bav[2]},#{bav[3]} руб. с #{bav[1]} (по извещению)"],
            ['Организатор', 'государственное предприятие «МГЦН», г. Минск, ул. К. Маркса, 39, тел. +375 (17) 360-42-22'],
            ['Извещение', url]].select { |_, v| v && !v.empty? }
    out = []
    main.scan(%r{<table.*?</table>}m).each do |tb|
      rows = grid(tb)
      hi = rows.index { |r| columns(r) } or next
      cols = columns(rows[hi])
      hdr = rows[hi]
      lessor_t = rows[0...hi].flatten.find { |x| x =~ /\AАрендодатель/ }
      notes = []
      rows[(hi + 1)..].each_with_index do |r, i|
        v = cols.map { |k, j| [k, r[j].to_s.strip] }.to_h.reject { |_, x| x.empty? || x == '—' }
        if v['price'].to_s =~ /отмен|снят/i
          next   # предмет снят с аукциона — карточки нет (известная уйдёт в архив «снят»)
        end
        price = num(v['price'])
        unless price.positive? && (v['no'].nil? || v['no'] =~ /\A\d+\z/)
          notes << r.uniq.join(' ') if r.uniq.size <= 2 && !r.join.empty?   # «Отдельные условия …» — общее для поста
          next
        end
        n = v['no'] || (i + 1).to_s
        d = v['desc'].to_s
        area_m2 = if land then nil
                  elsif v['area'] then num(v['area'])
                  elsif (a = d[/площад\S*\s+([\d\s]+[.,]?\d*)\s*кв\.?\s*м/, 1]) then num(a)
                  end
        addr = v['addr'] || d[/по адресу:\s*(.+?)(?:\s*\(|,\s*наименование|\s+машино-место|\z)/, 1] ||
               title[/(г\.\s*Минск[^()]*|ул\.[^()]*)/, 1]
        addr = addr && addr.sub(/[\s,;.]+\z/, '')
        addr = "г. Минск, #{addr}" if addr && addr !~ /Минск|обл/
        lessor = v['lessor'] || lessor_t.to_s.sub(/\AАрендодатель\s*[—–−-]\s*/, '')[/\S.*/] || lessor0
        dep = v['deposit'] ? num(v['deposit']) : (hdr[cols['price']] =~ /задат/i ? price : nil)
        about = hdr.each_with_index.reject { |_, j| j == cols['no'] }.map { |h, j| [h.sub(/\s*\((?:бел\.\s*)?руб\.\)|,\s*бел\.\s*руб\./, ''), r[j]] }
                   .reject { |_, x| x.to_s.empty? || x == '—' }.uniq
        secs = [{ 'h' => 'Об объекте', 'rows' => about }, { 'h' => 'Условия торгов', 'rows' => cond }]
        lterm = v['term'] || t[/в аренду сроком на ([^.,;]+)/, 1]
        rec = { 'key' => "mg-#{id}-#{n}", 'platform' => 'mgcn.by', 'art' => [no || id, n].join('/'), 'sec' => sec, 'url' => url,
                'name' => name_of(sec, land, v, area_m2, "#{hdr.join(' ')} #{title}", lterm, title =~ /строительств/i), 'price' => price,
                'req_to' => req, 'torg' => torg }
        rec['d'] = { 'details' => secs, 'location' => addr, 'req_to' => req, 'torg' => torg, 'debtor' => lessor.to_s.empty? ? nil : lessor,
                     'photos' => [],   # фото МГЦН не публикует: пустой список — pics.rb не будет искать галерею
                     'area_num' => land ? (num(v['area']) * 10_000).round : area_m2,
                     'terms' => dep ? { 'deposit' => dep, 'v' => 2 } : { 'v' => 2 },
                     'rent' => sec == 'arenda' && v['rate'] ? rent(v['rate'], hdr[cols['rate']], area_m2) : nil }
        rec['bav'] = [bav[1], "#{bav[2]}.#{bav[3]}".to_f] if bav
        out << rec
      end
      out.each { |x| x['d']['details'] << { 'h' => 'Дополнительно', 'rows' => notes.map { |s| ['', s] } } } unless notes.empty?
    end
    out
  end

  # все предстоящие предметы раздела; nil — список не прочитан
  def list(part)
    ps = posts(part) or return nil
    ps.flat_map do |u, title|
      sleep 1
      html = Src.get(u) or next []
      items(u, title, part, html)
    end
  end
end
