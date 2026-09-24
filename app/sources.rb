# encoding: utf-8
#
# Разбор трёх площадок: e-auction.by, ipmtorgi.by, beltorgi.by.
# Для каждой — список активных карточек раздела и разбор страницы лота.
# Карточка списка: key, platform, art, name, price, req_to, url, thumb (+ служебные поля).
# Страница лота: details (секции «ключ — значение»), location, debtor, area, torg, photo.
require 'json'
require 'time'
require 'tmpdir'
require_relative 'pdftext'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
ENV['TZ'] = 'Europe/Minsk'   # площадки пишут минское время без зоны

module Src
  UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
  EA = 'https://e-auction.by'
  IPM = 'https://ipmtorgi.by'
  BT = 'https://beltorgi.by'
  CPO = 'https://www.cpo.by'
  KF = 'https://konfiskat.by'
  MAX_PAGES = 40

  EA_SUBS = {
    'kvartiry_i_komnaty' => 'Квартиры и комнаты', 'doma' => 'Дома', 'garazhi' => 'Гаражи',
    'mashinomesta' => 'Машиноместа', 'kommercheskaya_nedvizhimost' => 'Коммерческая недвижимость',
    'sklady_i_proizvodstva' => 'Склады и производства', 'zemelnye_uchastki' => 'Земельные участки',
    'kompleks_imushchestva' => 'Комплекс имущества', 'dolya_v_imushchestve' => 'Доля в имуществе',
    'ne_zavershennyy_stroitelstvom_obekt' => 'Незавершённое строительство',
    'pravo_arendy' => 'Право аренды', 'drugoe' => 'Другое'
  }.freeze

  module_function

  def get(url)
    2.times do
      out = IO.popen(['curl', '-sS', '-L', '-m', '40', '-A', UA, url], err: File::NULL, &:read)
      out = out.to_s.force_encoding('UTF-8')
      return out if out.size > 1500
      sleep 2
    end
    nil
  end

  def post_json(url, data)
    out = IO.popen(['curl', '-sS', '-m', '60', '-A', UA, '-H', 'X-Requested-With: XMLHttpRequest',
                    '-d', data, url], err: File::NULL, &:read)
    JSON.parse(out.to_s.force_encoding('UTF-8'))
  rescue JSON::ParserError
    nil
  end

  def txt(s)
    s.to_s.gsub(/<button.*?<\/button>/m, ' ').gsub(/<br\s*\/?>|<\/p>/i, ' ').gsub(/<[^>]*>/, ' ')
     .gsub('&nbsp;', ' ').gsub('&quot;', '"').gsub('&laquo;', '«').gsub('&raquo;', '»')
     .gsub('&amp;', '&').gsub('&#039;', "'").gsub(/\s+/, ' ').strip
  end

  def num(s)
    s.to_s.gsub(/[^\d,.]/, '').tr(',', '.').to_f
  end

  # «22.10.2026г. 16:00», «22.10.2026 | 16:00», «22.10.2026 16:00:00»
  def ts(s)
    m = s.to_s.match(/(\d{2})\.(\d{2})\.(\d{4})\D+(\d{1,2}):(\d{2})/) or return nil
    Time.local(m[3].to_i, m[2].to_i, m[1].to_i, m[4].to_i, m[5].to_i).to_i
  end

  # «1 743», «0.1121 (га)» → м²
  def area_m2(key, val)
    n = val.to_s.tr(',', '.').gsub(/[^\d.]/, '')[/\d+(\.\d+)?/].to_f
    return nil if n.zero?
    "#{key} #{val}" =~ /\(га\)|\bга\b/ ? (n * 10_000).round : n
  end

  def rows_find(secs, re)
    (secs.flat_map { |s| s['rows'] }.find { |k, _| k =~ re } || [])[1]
  end

  # ---------------- e-auction.by ----------------
  # Пагинация за последней страницей повторяет её же — стоп на повторах.
  def ea_list(path)
    out = []
    seen = {}
    (1..MAX_PAGES).each do |p|
      html = get(p == 1 ? "#{EA}#{path}" : "#{EA}#{path}?PAGEN_1=#{p}") or break
      got = html.split('class="product-item column').drop(1).map do |ch|
        ch = ch[0, 6000]
        href = ch[/href="(\/[^"]+)"/, 1]
        art = ch[/class="product_art"[^>]*>\s*([0-9.]+)/m, 1]
        next nil unless href && art
        { 'key' => "ea-#{art}", 'platform' => 'e-auction.by', 'art' => art,
          'name' => txt(ch[/class="text-header">\s*([^<]*)/m, 1]),
          'sub' => href.split('/').reject(&:empty?)[1],
          'price' => ch[/data-cur="BYN" data-value="([0-9.]+)"/, 1].to_f,
          'req_to' => ch[/data-endrequest="(\d+)"/, 1].to_i,
          'url' => EA + href,
          'thumb' => (u = ch[/<img src="(\/upload\/[^"]+)"/, 1]) && EA + u }
      end.compact
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh)
      sleep 0.6
    end
    out
  end

  def ea_detail(html)
    secs = []
    cur = nil
    html.scan(/product-specs__table-title-inner">(.*?)<\/div>|product-specs__table-td-name"[^>]*>(.*?)<\/td>\s*<td[^>]*>(.*?)<\/td>/m) do |title, k, v|
      if title
        cur = { 'h' => txt(title)[0, 70], 'rows' => [] }
        secs << cur
      else
        key = txt(k)
        val = txt(v)
        next if key.empty? || val.empty?
        cur ||= (secs << { 'h' => 'Сведения о лоте', 'rows' => [] }).last
        cur['rows'] << [key, val]
      end
    end
    secs.reject! { |s| s['rows'].empty? }
    i = html.index('class="gallery-items"') || html.index('class="image-slides"')
    pic = i && html[i, 9000][%r{(?:src|href|data-src)="(/upload/[^"]+\.(?:jpg|jpeg|png))"}i, 1]
    area = rows_find(secs, /Площадь общая/)
    { 'details' => secs,
      'location' => rows_find(secs, /Местоположение/),
      'debtor' => rows_find(secs, /^Должник/),
      'area_num' => area && area_m2('Площадь', area),
      'photo_url' => pic && EA + pic, 'terms' => ea_terms(html) }
  end

  # Условия покупки для калькулятора. На e-auction: «задаток в размере 538.17 BYN»,
  # «Первая ставка - 5% от начальной цены», «Лимиты установки ставки: от … (0.5%) до … (5%)»,
  # единственный участник покупает «по начальной цене … плюс 5%». Арестованное имущество НДС не облагается.
  def ea_terms(html)
    tx = txt(html.gsub(/<script.*?<\/script>|<style.*?<\/style>/m, ''))
    t = {}
    t['deposit'] = num(tx[/задаток в размере\s*([\d\s.,]+?)\s*BYN/, 1])
    t['first_pct'] = num(tx[/Первая ставка\s*-\s*([\d.,]+)\s*%/, 1])
    if (m = tx.match(/Лимиты установки ставки:\s*от[^(]*\(([\d.,]+)\s*%\)\s*до[^(]*\(([\d.,]+)\s*%\)/))
      t['step_min_pct'] = num(m[1])
      t['step_pct'] = num(m[2])
      t['step_base'] = 'start'
    end
    t['single_pct'] = num(tx[/по начальной цене [\d\s.,]+ BYN плюс ([\d.,]+)\s*%/, 1])
    t['vat'] = 'НДС не облагается — реализация арестованного имущества' if tx.include?('реализации арестованного имущества')
    t.reject { |_, v| v.nil? || v == 0.0 }
  end

  # ---------------- ipmtorgi.by ----------------
  # Список отсортирован по сроку заявок по убыванию и тянет архив до 2019 года:
  # после первой страницы с закрытыми лотами активных дальше нет.
  def ipm_list(path)
    out = []
    seen = {}
    now = Time.now.to_i
    (1..MAX_PAGES).each do |p|
      html = get(p == 1 ? "#{IPM}#{path}" : "#{IPM}#{path}?PAGEN_1=#{p}") or break
      got = html.split('class="c-list__item"').drop(1).map do |ch|
        ch = ch[0, 4000]
        url = ch[/href="(https:\/\/ipmtorgi\.by\/auctions\/[^"]+)"/, 1] or next
        d = ch[/c-list__item-info__date"><span>[^<]*<\/span>\s*<span>\s*([^<]*)<\/span>/m, 1]
        img = ch[/background-image: url\('(\/upload\/[^']+)'\)/, 1]
        { 'key' => "ipm-#{url.split('/').reject(&:empty?).last}", 'platform' => 'ipmtorgi.by',
          'art' => url.split('/').reject(&:empty?).last[/\A\d+/] || url.split('/').last,
          'name' => txt(ch[/c-list__item-info__name">\s*([^<]*)/m, 1]),
          'price' => txt(ch[/Начальная цена:<\/span>\s*<span>\s*([0-9 .,]+)\s*BYN/m, 1]).gsub(/[^0-9.]/, '').to_f,
          'req_to' => ts(d),
          'location' => txt(ch[/location--addr">\s*([^<]*)/m, 1]),
          'url' => url, 'thumb' => img && IPM + img }
      end.compact
      break if got.empty?
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh.select { |c| c['req_to'].to_i > now })
      oldest = got.map { |c| c['req_to'] }.compact.min
      break if oldest && oldest < now
      sleep 0.6
    end
    out
  end

  def ipm_detail(html, host = IPM)
    # заголовок секции стоит ПЕРЕД блоком строк — сшиваем по порядку
    heads = html.scan(/aution-inform-zag">(.*?)<\/div>/m).flatten.map { |h| txt(h) }
    secs = []
    html.split('aution-inform__items').drop(1).each_with_index do |blk, i|
      rows = blk[0, 20_000].scan(/<li>\s*<div>(.*?)<\/div>\s*<div>(.*?)<\/div>/m)
                           .map { |k, v| [txt(k), txt(v)] }.reject { |k, v| k.empty? && v.empty? }
      next if rows.empty?
      h = heads[i].to_s
      secs << { 'h' => h.empty? ? 'Сведения о лоте' : h[0, 70], 'rows' => rows }
    end
    subject = (secs.find { |s| s['h'] =~ /предмет(е)? торгов|^Сведения о лоте/ } || { 'rows' => [] })['rows']
    seller = (secs.find { |s| s['h'] =~ /продавц/i } || { 'rows' => [] })['rows']
    arow = (subject + secs.flat_map { |s| s['rows'] }).find { |k, v| k =~ /площад/i && area_m2(k, v) }
    i = html.index('class="auction-gallery__main"') || html.index('class="auction-gallery"')
    pic = i && html[i, 9000][%r{(?:src|href|data-src|data-large)="(/upload/[^"]+\.(?:jpg|jpeg|png))"}i, 1]
    { 'details' => secs,
      'lotno' => txt(html[/aution-main__lot">.*?<b>(.*?)<\/b>/m, 1]),
      # цена бывает в USD/EUR — площадка сама показывает пересчёт в BYN
      'price_byn' => num(html[/class="valute_price">\s*<div><b>([\d\s.,]+)<\/b>\s*BYN/, 1]),
      'req_to' => ts(txt(html[/Время окончания приёма заявок:<\/b>\s*<br\s*\/?>\s*([^<]+)/m, 1]).gsub('&nbsp;', ' ')),
      'torg' => ts(txt(html[/Время начала торгов:<\/b>\s*<br\s*\/?>\s*([^<]+)/m, 1]).gsub('&nbsp;', ' ')),
      'area_num' => arow && area_m2(arow[0], arow[1]),
      'debtor' => (seller.find { |k, _| k =~ /Наименование/ } || [])[1],
      'photo_url' => pic && host + pic, 'terms' => ipm_terms(html) }
  end

  # «Шаг аукциона: 5% от текущей цены», «Сумма задатка: 3 336.96 BYN»,
  # «Кроме цены за лот победитель оплачивает: затраты: 300,00 руб.», «вознаграждение организатору торгов 8% от цены продажи»,
  # единственный участник — «по начальной цене предмета аукциона, увеличенной на 5%»
  def ipm_terms(html)
    i = html.index('auction-bet') or return {}
    tx = txt(html[i, 12_000])
    all = txt(html.gsub(/<script.*?<\/script>|<style.*?<\/style>/m, ''))
    t = {}
    t['deposit'] = num(tx[/Сумма задатка:\s*([\d\s.,]+?)\s*BYN/, 1])
    if (m = tx.match(/Шаг аукциона:\s*([\d.,]+)\s*%\s*от\s*(текущей|начальной)/))
      t['step_pct'] = num(m[1])
      t['step_base'] = m[2] == 'текущей' ? 'current' : 'start'
    elsif (m = tx.match(/Шаг аукциона:\s*([\d\s.,]+?)\s*BYN/))
      t['step_abs'] = num(m[1])
    end
    t['fee_abs'] = num(tx[/затраты:\s*([\d\s.,]+?)\s*руб/, 1])
    t['fee_pct'] = num(tx[/вознаграждение организатору торгов\s*([\d.,]+)\s*%/, 1])
    t['vat'] = tx[/(С учетом НДС|Без учета НДС|НДС не облагается)/i, 1]
    t['single_pct'] = num(all[/согласившимся приобрести предмет аукциона по начальной цене предмета аукциона, увеличенной на (\d+)\s*%/, 1])
    t.reject { |_, v| v.nil? || v == 0.0 }
  end

  # ---------------- beltorgi.by ----------------
  # Каталог грузится скриптом: страница раздела отдаёт content_id и cachekey (меняется при
  # каждом открытии), карточки приходят JSON-ом из POST /assets/category.php, по 80.
  def bt_list(slug)
    page = get("#{BT}/#{slug}/") or return []
    cid = page[/name="content_id" value="(\d+)"/, 1]
    key = page[/name="cachekey" value="(\d+)"/, 1]
    return [] unless cid && key
    form = "content_id=#{cid}&cachekey=#{key}&tpl=CardTplList&view=tab&tpltable=CardTplTable" \
           '&ListWrapper=ListWrapper&filtr%5Barray%5D%5Bresult%5D=1%2C6%2C8&limit=80&sort=1&order=1'
    seen = {}
    out = []
    (1..MAX_PAGES).each do |p|
      j = post_json("#{BT}/assets/category.php", form + "&page=#{p}") or break
      got = j['output'].to_s.split('class="col mb-4"').drop(1).map do |ch|
        id = ch[/card-img-top-(\d+)/, 1] or next
        href = ch[/<a class="text-dark" href="([^"]+)"/, 1] or next
        thumb = ch[%r{src="(/assets/images/products/\d+/small/[^"]+)"}, 1]
        { 'key' => "bt-#{id}", 'platform' => 'beltorgi.by', 'art' => ch[/Лот №\s*(\d+)/, 1] || id,
          'name' => txt(ch[/class="card-title[^"]*">(.*?)<\/a>/m, 1]),
          'region' => txt(ch[/bi-geo-alt"><\/i>([^<]*)/, 1]).tr('ё', 'е').sub(/обл\.?\z/, 'область'),
          'price' => num(ch[/<span class="price"><span>([^<]+)/, 1]),
          # «До начала приема заявок» — лот объявлен, но заявки ещё не принимают
          'open' => ch.include?('До окончания приема заявок'),
          # срока в списке нет — только обратный отсчёт; по нему видно, что лот перевыставили
          'est' => bt_left(ch),
          'url' => "#{BT}/#{href}",
          'thumb' => thumb && BT + thumb.sub('/small/', '/big/') }
      end.compact
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh)
      sleep 0.6
    end
    out
  end

  # «29дн 01час 18мин» → прикидка срока заявок, unix
  def bt_left(ch)
    title, left = ch.match(/class="clock" title="([^"]*)">(.*?)<\/div>/m).to_a.drop(1)
    return nil unless title.to_s.include?('окончания')
    left = txt(left)
    secs = { 'дн' => 86_400, 'час' => 3600, 'мин' => 60 }.sum { |u, k| left[/(\d+)\s*#{u}/, 1].to_i * k }
    secs.positive? ? Time.now.to_i + secs : nil
  end

  BT_ROW = begin
    d = '((?:(?!</div>).)*?)'   # до ближайшего </div>: с .*? регулярка уходит в перебор на 200 КБ
    Regexp.new(
      '<div class="row([^"]*)" style="background: #ddd;"><div class="col py-2 px-3"\s*><b>([^<]*)</b>|' \
      '<div class="d-flex justify-content-between[^"]*border-bottom py-1">\s*<div>' + d + '</div>\s*<div>' + d + '</div>|' \
      '<div class="row([^"]*)"[^>]*>\s*<div class="col-(?:5|12) col-lg-3[^"]*"[^>]*>' + d + '</div>\s*' \
      '<div class="col-(?:7|12) col-lg-9">' + d + '</div>', Regexp::MULTILINE)
  end

  def bt_detail(html)
    secs = [{ 'h' => 'Условия торгов', 'rows' => [] }]
    cur = secs.first
    html.scan(BT_ROW) do |hcls, title, k1, v1, rcls, k2, v2|
      if title
        cur = { 'h' => txt(title), 'rows' => [], 'hidden' => hcls.include?('d-none') }
        secs << cur
        next
      end
      next if rcls.to_s.include?('d-none') || cur['hidden']
      k = txt(k1 || k2)
      v = txt(v1 || v2)
      next if k.empty? || v.empty? || k =~ /Допущено участников|Текущая ставка/
      cur['rows'] << [k, v] unless cur['rows'].include?([k, v])
    end
    secs.each { |s| s.delete('hidden') }
    secs.reject! { |s| s['rows'].empty? }
    title = txt(html[/<h1[^>]*>(.*?)<\/h1>/m, 1])
    area = rows_find(secs, /площадь/i) || title[/(\d[\d\s]*(?:[.,]\d+)?)\s*кв\.?\s*м/, 1]
    { 'details' => secs,
      'title' => title,
      'location' => rows_find(secs, /Местонахождение/),
      'debtor' => rows_find(secs, /Собственник/),
      'req_to' => ts(rows_find(secs, /Окончание подачи заявок/)),
      'torg' => ts(rows_find(secs, /Начало торгов/)),
      'area_num' => area && (a = num(area)).positive? ? a : nil,
      'terms' => bt_terms(secs, html) }
  end

  # «Сумма задатка», «Шаг торгов» (фиксированный, в рублях), «Срок уплаты задатка», «Минимальная стоимость»;
  # про НДС — строкой над датами: «Цена с НДС (НДС в том числе по ставке 20%)»
  def bt_terms(secs, html = nil)
    t = {}
    t['deposit'] = num(rows_find(secs, /Сумма задатка/))
    t['deposit_to'] = ts(rows_find(secs, /Срок уплаты задатка/))
    t['step_abs'] = num(rows_find(secs, /Шаг торгов/))
    t['min_price'] = num(rows_find(secs, /Минимальная стоимость/))
    t['vat'] = txt(html[/<div class="py-3">\s*([^<]*НДС[^<]*)</, 1]) if html
    t = t.reject { |_, v| v.nil? || v == 0.0 || v == '' }
    # Сверх цены покупатель платит (строка «Обязанности»): «аукционный сбор в размере 7.9% от цены продажи»
    # и «возмещает затраты на организацию и проведение торгов в размере 55,00 бел. руб.» — сумма бывает
    # пустой («в размере в течение 5 дней…»): «точная сумма будет известна до начала торгов»
    duty = rows_find(secs, /\AОбязанности\z/).to_s
    pct = duty[/аукционный сбор в размере\s*([\d.,]+)\s*%/, 1]
    t['fee_pct'] = num(pct) if pct                       # 0% — тоже ответ: сбор не берут
    if duty =~ /возмещает затраты на организацию и проведение торгов в размере\s*([\d\s.,]+?)\s*бел/
      t['fee_abs'] = num($1)
    elsif duty.include?('затраты на организацию')
      t['fee_later'] = true
    end
    t['v'] = 2
    t
  end
  # ---------------- cpo.by (ЗАО «Центр промышленной оценки») ----------------
  # Сайт организатора; торги он проводит на ipmtorgi.by, поэтому лоты почти все те же, с тем же
  # номером и сроками. Список — по 9, по дате аукциона от поздних к ранним, с архивом: стоп на первой
  # странице, где есть прошедшие даты. Страница лота — шаблон ИПМ (ipm_detail с хостом ЦПО).
  def cpo_list(section)
    out = []
    seen = {}
    today = Time.now.to_i - 86_400
    (1..MAX_PAGES).each do |p|
      html = get("#{CPO}/auctions/filter/section-is-#{section}/apply/" + (p > 1 ? "?PAGEN_1=#{p}" : '')) or break
      got = html.split('class="sales__item"').drop(1).map do |ch|
        ch = ch[0, 5000]
        slug = ch[%r{href="https://www\.cpo\.by/auctions/([^/"]+)/"}, 1] or next
        day = ts(ch[/sales__item-title-date.*?(\d{2}\.\d{2}\.\d{4})/m, 1].to_s + ' 00:00')
        pr = txt(ch[/sales__item-price__bottom[^>]*>(.*?)<div class="valute_price"/m, 1]).gsub('&nbsp;', '')
        img = ch[/background-image: url\('(\/upload\/[^']+)'\)/, 1]
        { 'key' => "cpo-#{slug}", 'platform' => 'cpo.by', 'art' => slug,
          'name' => txt(ch[/sales__item-title-title">(.*?)<\/div>/m, 1]),
          'price' => pr.include?('BYN') ? num(pr[/[\d\s.,]+(?=\s*BYN)/]) : 0.0,
          'day' => day, 'location' => txt(ch[/location--addr"><span>(.*?)<\/span>/m, 1]),
          'url' => "#{CPO}/auctions/#{slug}/", 'thumb' => img && CPO + img }
      end.compact
      break if got.empty?
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh.select { |c| c['day'].to_i >= today })
      break if got.map { |c| c['day'] }.compact.min.to_i < today
      sleep 0.6
  end
    out
  end

  # ---------------- konfiskat.by (РУП «Торговый дом «Восточный») ----------------
  # Аукционы: автотранспорт (основное), недвижимость, прочее имущество. В карточке — дата аукциона,
  # срок заявок и задаток — только в PDF-извещении (одно на аукцион, ссылка — на странице лота):
  # «состоится 20.10.26 в 12:00 г. Минск», «Не позднее 12.00 дня, предшествующего дню проведения
  # электронных торгов…», «Размер задатка – 10% от начальной цены продажи».
  def kf_list(path)
    out = []
    seen = {}
    (1..MAX_PAGES).each do |p|
      html = get("#{KF}/#{path}/" + (p > 1 ? "?PAGEN_1=#{p}" : '')) or break
      got = html.split('class="product-card grid-card-style"').drop(1).map do |ch|
        href = ch[/class="product-name"[^>]*href="([^"]+)"|href="([^"]+)"[^>]*class="product-name"/, 1] ||
               ch[/href="([^"]+)"[^>]*class="product-name"/, 1]
        id = href.to_s[%r{/(\d+)/\z}, 1] or next
        img = ch[/<img src="(\/upload\/[^"]+)"/, 1]
        { 'key' => "kf-#{id}", 'platform' => 'konfiskat.by', 'art' => ch[/Лот №\s*(\d+)/, 1] || id,
          'name' => txt(ch[/class="product-name"[^>]*>(.*?)<\/a>/m, 1]),
          'price' => num(txt(ch[/product-price-new[^>]*>\s*<span>([^<]+)/m, 1]).gsub('&nbsp;', '')),
          'day' => ts(txt(ch[/auction-date.*?<\/svg>(.*?)<\/span>/m, 1]).gsub('&nbsp;', ' ')[/\d{2}\.\d{2}\.\d{4}/].to_s + ' 00:00'),
          'url' => KF + href, 'thumb' => img && KF + img }
      end.compact
      break if got.empty?
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh)
      sleep 1.5   # konfiskat.by закрывает доступ при частых запросах
  end
    out
  end

  NOTICES = {}
  NOTICE_LOCK = Mutex.new

  # Извещение читаем один раз на прогон: оно общее для десятков лотов одного аукциона
  def kf_notice(url)
    NOTICE_LOCK.synchronize do
      return NOTICES[url] if NOTICES.key?(url)
      tmp = File.join(Dir.tmpdir, "kf-notice-#{url.hash.abs}.pdf")
      system('curl', '-sS', '-L', '-m', '60', '-A', UA, '-o', tmp, url, out: File::NULL, err: File::NULL)
      t = (File.exist?(tmp) ? PdfText.text(tmp) : '').gsub(/\s+/, ' ') rescue ''
      File.delete(tmp) if File.exist?(tmp)
      n = {}
      if (m = t.match(/состоится\s+(\d{2})\.(\d{2})\.(\d{2,4})\s+в\s+(\d{1,2})[:.](\d{2})/))
        y = m[3].size == 2 ? 2000 + m[3].to_i : m[3].to_i
        n['torg'] = Time.local(y, m[2].to_i, m[1].to_i, m[4].to_i, m[5].to_i).to_i
        n['city'] = t[/состоится\s+[\d.]+\s+в\s+[\d:.]+\s*(?:г\.)?\s*г\.\s*([А-ЯЁ][а-яё-]+)/, 1] ||
                    t[/состоится.{0,40}?г\.\s*([А-ЯЁ][а-яё-]+)/, 1]
      end
      if n['torg'] && (m = t.match(/Не позднее\s+(\d{1,2})[.:](\d{2})\s+дня,\s+предшествующего дню проведения/i))
        d = Time.at(n['torg'] - 86_400)
        n['req_to'] = Time.local(d.year, d.month, d.day, m[1].to_i, m[2].to_i).to_i
      end
      n['deposit_pct'] = num(t[/Размер задатка\s*[–-]\s*([\d.,]+)\s*%/, 1])
      n['pay'] = t[/окончательные расчеты[^.]{0,120}?(в течение\s+\d+[^.,;]{0,40})/i, 1]
      NOTICES[url] = n if n['torg']   # не скачалось — попробуем для следующего лота
      n
  end
  end

  def kf_detail(html, card = {})
    secs = []
    extra = txt(html[/Дополнительная информация:\s*<\/p>(.*?)<\/div>/m, 1] || html[/Дополнительная информация:(.*?)<\/p>\s*<p/m, 1])
    rows = html.scan(/<li><p><span>([^<]+):<\/span>(.*?)<\/p><\/li>/m).map { |k, v| [txt(k), txt(v)] }
               .reject { |k, v| v.empty? || k =~ /Ссылка на извещение/ }
    secs << { 'h' => 'Информация о предмете торгов', 'rows' => rows } unless rows.empty?
    secs.first['rows'].unshift(['Описание', extra]) if !extra.empty? && secs.first
    pdf = html[%r{href="(/upload/[^"]+\.pdf)"}i, 1]
    n = pdf ? kf_notice(KF + pdf) : {}
    day = card['day'] || ts(html[/Дата проведения аукциона:.*?(\d{2}\.\d{2}\.\d{4})/m, 1].to_s + ' 00:00')
    torg = n['torg'] || (day && day + 12 * 3600)
    # правило из извещений: заявки — до 12:00 дня, предшествующего аукциону
    req = n['req_to'] || (torg && Time.at(torg - 86_400).then { |d| Time.local(d.year, d.month, d.day, 12, 0).to_i })
    cond = [['Дата аукциона', torg && Time.at(torg).strftime('%d.%m.%Y %H:%M')],
            ['Приём заявок до', req && Time.at(req).strftime('%d.%m.%Y %H:%M')],
            ['Задаток', "#{(n['deposit_pct'] || 10).to_s.sub(/\.0\z/, '')}% от начальной цены"],
            ['Извещение', pdf && KF + pdf]].select { |_, v| v }
    secs.unshift({ 'h' => 'Условия торгов', 'rows' => cond })
    pics = html.scan(%r{src="(/upload/(?:avto|iblock|resize_cache)[^"]+\.(?:jpg|jpeg|png))"}i).flatten.uniq
    owner = extra[/Находится в собственности\s+([^.]+)/, 1]
    { 'details' => secs, 'req_to' => req, 'torg' => torg,
      'location' => n['city'] ? "г. #{n['city']}" : nil, 'debtor' => owner ? owner.strip : 'Конфискованное имущество',
      'photo_url' => pics.first && KF + pics.first,
      'terms' => { 'deposit' => card['price'].to_f * (n['deposit_pct'] || 10) / 100, 'fee_later' => true,
                   'pay_term' => n['pay'], 'v' => 2 }.reject { |_, v| v.nil? || v == 0.0 } }
  end

end
