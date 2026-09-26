# encoding: utf-8
#
# Разбор площадок: e-auction.by, ipmtorgi.by, beltorgi.by, konfiskat.by (торги — на torgikonfiskat.by), belauction.by.
# Для каждой — список активных карточек раздела, разбор страницы лота и список завершённых торгов (архив).
# cpo.by (ЦПО) с 25.09.2026 не собираем: это рекламная витрина торгов ИПМ.
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
  KF = 'https://konfiskat.by'
  TK = 'https://torgikonfiskat.by'
  BA = 'https://belauction.by'
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

  # ---------------- фото лота ----------------
  # Все фото из галереи карточки площадки — ссылками (сами файлы не копируем: ~10–20 фото × 4 500 лотов — больше
  # гигабайта, предел GitHub Pages). Сайт показывает их с площадки; главное фото хранится у нас (Store.save_photo).
  # Берём только галерею лота — без иконок, баннеров и фото соседних лотов:
  #   e-auction  data-mfp-src в .gallery-items (версии 1200×900)
  #   ИПМ        ссылки слайдов .auction-gallery__main-slide (оригиналы)
  #   beltorgi   /assets/images/products/<id лота>/big/… (id — самый частый в big: у соседних лотов — small)
  #   konfiskat  /upload/avto/<код>…; torgikonfiskat — так же
  #   belauction <a href=… data-fancybox=images>
  # base — сайт, с которого страница (у konfiskat бывает konfiskat.by или torgikonfiskat.by)
  def photos(platform, html, base = nil)
    h = html.to_s
    list = case platform
           when 'e-auction.by'
             blk = h[/gallery-items(.*?)<\/div>/m, 1].to_s
             blk.scan(/data-mfp-src="([^"]+)"/).flatten.map { |u| EA + u }
           when 'ipmtorgi.by'
             h.scan(%r{auction-gallery__main-slide">\s*<a href="(/upload/[^"]+)"}).flatten.map { |u| IPM + u }
           when 'beltorgi.by'
             big = h.scan(%r{/assets/images/products/(\d+)/big/([^"'\s)]+\.(?:jpe?g|png|webp))}i)
             id = big.map(&:first).group_by(&:itself).max_by { |_, v| v.size }&.first
             big.select { |i, _| i == id }.map { |i, f| "#{BT}/assets/images/products/#{i}/big/#{f}" }
           when 'konfiskat.by'
             h.scan(%r{(?:src|href|data-src)="(/upload/avto/[^"]+\.(?:jpe?g|png))"}i).flatten.map { |u| (base || KF) + u }
           when 'belauction.by'
             h.scan(%r{href=["']?(https://belauction\.by/wp-content/uploads/[^\s"'>]+?\.(?:jpe?g|png|webp))["']?\s+data-fancybox=["']?images}i).flatten
           else []
           end
    list.uniq   # все фото карточки, без ограничения
  end

  # ---------------- e-auction.by ----------------
  # Пагинация за последней страницей повторяет её же — стоп на повторах.
  # since — архив: вкладка «Завершённые» (?type=f), по сроку заявок от поздних к ранним; берём лоты со сроком после since
  def ea_list(path, since: nil)
    out = []
    seen = {}
    (1..(since ? 80 : MAX_PAGES)).each do |p|
      q = [since && 'type=f', p > 1 && "PAGEN_1=#{p}"].select { |x| x }.join('&')
      html = get("#{EA}#{path}" + (q.empty? ? '' : "?#{q}")) or break
      got = html.split('class="product-item column').drop(1).map do |ch|
        ch = ch[0, 6000]
        href = ch[/href="(\/[^"]+)"/, 1]
        art = ch[/class="product_art"[^>]*>\s*([0-9.]+)/m, 1]
        next nil unless href && art
        { 'key' => "ea-#{art}", 'platform' => 'e-auction.by', 'art' => art,
          'name' => txt(ch[/class="text-header">\s*([^<]*)/m, 1]),
          'sub' => href.split('/').reject(&:empty?)[1],
          'price' => ch[/data-cur="BYN" data-value="([0-9.]+)"/, 1].to_f,
          'req_to' => ch[/data-endrequest="(\d+)"/, 1].to_i, 'start_req' => ch[/data-startrequest="(\d+)"/, 1].to_i,
          'url' => EA + href, 'eid' => ch[/product-id="(\d+)"/, 1],   # номер торгов — по нему итоги и дата онлайн-торгов
          'thumb' => (u = ch[/<img src="(\/upload\/[^"]+)"/, 1]) && EA + u }
      end.compact
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(since ? fresh.select { |c| c['req_to'] >= since } : fresh)
      break if since && fresh.map { |c| c['req_to'] }.max.to_i < since
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
      'photo_url' => pic && EA + pic, 'photos' => photos('e-auction.by', html), 'terms' => ea_terms(html) }
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
  # since — архив: листаем дальше и берём лоты, у которых приём заявок закрылся после since
  def ipm_list(path, since: nil)
    out = []
    seen = {}
    now = Time.now.to_i
    lo = since || now
    (1..(since ? 80 : MAX_PAGES)).each do |p|
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
      out.concat(fresh.select { |c| since ? c['req_to'].to_i.between?(since, now) : c['req_to'].to_i > now })
      oldest = got.map { |c| c['req_to'] }.compact.min
      break if oldest && oldest < lo
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
      'photo_url' => pic && host + pic, 'photos' => photos('ipmtorgi.by', html), 'terms' => ipm_terms(html) }
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
  # Каталог — обычные страницы /<раздел>/?limit=80&page=N (с 25.09.2026; раньше карточки приходили
  # JSON-ом из POST /assets/category.php). По умолчанию площадка показывает «приём заявок» и «ожидание приёма».
  # Архив — тот же каталог с фильтром status: 2,3 — состоявшиеся торги, 4,5,12,13 — несостоявшиеся
  # (ожидаются повторные); sort=3&dir=0 — по дате аукциона от поздних к ранним. Дат в карточке нет — они на странице лота.
  BT_DONE = { 'sold' => '2%2C3', 'failed' => '4%2C5%2C12%2C13' }.freeze

  def bt_page(slug, page, status = nil)
    html = get("#{BT}/#{slug}/?limit=80&page=#{page}" + (status ? "&status=#{status}&sort=3&dir=0" : '')) or return nil
    html.split('class="col mb-4"').drop(1).map do |ch|
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
  end

  def bt_list(slug)
    seen = {}
    out = []
    (1..MAX_PAGES).each do |p|
      got = bt_page(slug, p) or break
      fresh = got.reject { |c| seen[c['key']] }
      break if fresh.empty?
      fresh.each { |c| seen[c['key']] = true }
      out.concat(fresh)
      break if got.size < 80
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
      'photos' => photos('beltorgi.by', html), 'terms' => bt_terms(secs, html) }
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
  # ---------------- torgikonfiskat.by — торги konfiskat.by ----------------
  # Аукционы konfiskat.by проходят на torgikonfiskat.by. Для архива берём оттуда каталог автотранспорта
  # с фильтром статуса: «Завершены» (80|81) — последние дни, «Архив» — всё прошлое. По дате аукциона
  # от поздних к ранним, по 8 на странице. «Лот №» на странице торгов — тот же номер, что у лота на konfiskat.by.
  def tk_archive(since)
    out = []
    seen = {}
    now = Time.now.to_i
    %w[80%7C81 ARCHIVE].each do |st|
      (1..250).each do |p|
        html = get("#{TK}/auto-auction/?arrFilter_pf%5BPROPERTY_UF_AUC_STATUS%5D=#{st}&set_filter=Apply" + (p > 1 ? "&PAGEN_1=#{p}" : '')) or break
        got = html.scan(/product-card mini-card" id="bx_\d+_(\d+)".*?class="date">\s*([^<]+?)\s*<\/span>.*?<img src="([^"]+)".*?class="product-title"\s*>\s*([^<]+?)\s*<\/a>.*?class="price">(.*?)<\/p>/m)
                  .map do |id, d, img, name, pr|
          { 'tk_id' => id, 'day' => ts(d), 'name' => txt(name), 'price' => num(pr.gsub('&#160;', '').gsub(/<[^>]+>/, '')),
            'url' => "#{TK}/auto-auction/#{id}/", 'thumb' => img.start_with?('/') ? TK + img : nil }
        end
        fresh = got.reject { |c| seen[c['tk_id']] }
        break if fresh.empty?
        fresh.each { |c| seen[c['tk_id']] = true }
        # в «Архиве» есть и снятые лоты с датой в будущем — это не завершённые торги
        out.concat(fresh.select { |c| c['day'].to_i.between?(since, now) })
        break if fresh.map { |c| c['day'].to_i }.max < since
        sleep 1
      end
    end
    out
  end

  # Страница торгов: характеристики «Ключ: значение», описание, фото, полное название — в <title>
  def tk_detail(html)
    rows = html.scan(/<li>\s*<p>([^<:]{2,80}):\s*<span>(.*?)<\/span><\/p>\s*<\/li>/m).map { |k, v| [txt(k), txt(v)] }
               .reject { |k, v| v.empty? || k =~ /Ссылка на извещение|Телефон|Код/ }
    extra = txt(html[/<h3>Дополнительная информация<\/h3>\s*<div class="text">(.*?)<\/div>/m, 1]).sub(/\s*Аукцион проводится.*/m, '')
    rows.unshift(['Описание', extra]) unless extra.empty?
    pics = html.scan(%r{src="(/upload/avto/[^"]+\.(?:jpg|jpeg|png))"}i).flatten.uniq
    { 'title' => txt(html[/<title>(.*?)<\/title>/m, 1]), 'art' => (rows.assoc('Лот №') || [])[1],
      'details' => rows.empty? ? [] : [{ 'h' => 'Информация о предмете торгов', 'rows' => rows }],
      'photo_url' => pics.first && TK + pics.first, 'photos' => pics.map { |u| TK + u } }
  end

  # ---------------- belauction.by (ООО «БелАукцион-Групп») ----------------
  # Частный онлайн-аукцион: транспорт с пробегом, аварийные авто, спецтехника, залоговое и банкротное имущество.
  # Ставки идут онлайн до «Завершения торгов» — это и срок, и дата торгов. Цена в карточке — текущая ставка.
  # robots.txt запрещает листать списки дальше первой страницы (*/page) и адреса с «?»: берём первые страницы
  # общего списка и каждой категории — вместе это почти все активные лоты (25.09: 63 из ~70); архив —
  # первые страницы «Проданные лоты» (≈ месяц) и «Завершённые аукционы» (≈ 10 дней). Пауза 2 с (Crawl-delay).
  BA_SEC = { 'legkovye-avtomobili' => 'avto', 'avarijnye-bitye-avtomobili' => 'avto', 'mototsikly-skutery' => 'avto',
             'gruzovye-avtomobili' => 'gruz', 'pritsepy-polupritsepy' => 'gruz', 'stroitelnaya-spetsialnaya-tehnika' => 'spec',
             'oborudovanie-i-prochaya-tehnika' => 'oborud', 'nedvizhimost' => 'nedvizhimost',
             'gosudarstvennaja-nedvizhimost' => 'nedvizhimost', 'chastnaja-nedvizhimost' => 'nedvizhimost' }.freeze   # запчасти не берём
  BA_ACTIVE = (%w[active-auctions auktsiony/transportnye-sredstva] + BA_SEC.keys.map { |k| "auktsiony/#{k}" }).freeze
  BA_DONE = %w[prodan-auction closed-auctions].freeze
  RU_MON = %w[января февраля марта апреля мая июня июля августа сентября октября ноября декабря].freeze

  # «25 сентября 2026» → полдень этого дня
  def ru_date(s)
    m = s.to_s.match(/(\d{1,2})\s+([а-я]+)\s+(\d{4})/) or return nil
    mon = RU_MON.index(m[2]) or return nil
    Time.local(m[3].to_i, mon + 1, m[1].to_i, 12, 0).to_i
  end

  def ba_cards(path)
    html = get("#{BA}/#{path}/") or return nil
    sleep 2
    now = Time.now.to_i
    html.split(/class=post\s+id=post-ID-/).drop(1).map do |ch|
      ch = ch[0, 5000]
      url = ch[%r{href=(https://belauction\.by/auctions/[^\s>]+/)}, 1] or next
      cat = url.split('/')[-2]
      sec = BA_SEC[cat] or next
      f = ch.scan(%r{small_ttl_h>(.*?)</div>(.*?)</li>}m).map { |k, v| [txt(k).sub(/:\z/, ''), txt(v)] }.to_h
      left = ch[/expiration_auction_p[^>]*>\s*(\d+)/, 1] || ch[/До окончания:.*?(\d{3,})/m, 1]
      img = ch[%r{src=(https://belauction\.by/wp-content/uploads/[^\s>]+)}, 1]
      { 'key' => "ba-#{ch[/\A\d+/]}", 'platform' => 'belauction.by', 'art' => txt(ch[/Лот №(.*?)<br/m, 1]).gsub(/\D/, ''),
        'name' => txt(ch[/title="([^"]+)"/, 1]), 'sec' => sec, 'url' => url,
        'price' => num(f['Текущая цена'] || f['Цена продажи'] || f['Закрыт по цене']),
        'sold' => f.key?('Цена продажи'), 'bids' => f['Ставки'].to_i,
        'closed_day' => ru_date(f['Закрытие торгов']), 'left' => left && now + left.to_i,
        'thumb' => img && img.sub(/-\d+x\d+(\.\w+)\z/, '\1') }
    end.compact
  end

  # активные: карточки с «Текущая цена» со всех первых страниц; done — архив (проданные и завершённые)
  def ba_list(kind = :active)
    seen = {}
    (kind == :active ? BA_ACTIVE : BA_DONE).flat_map { |p| ba_cards(p) || [] }.select do |c|
      next false if seen[c['key']]
      seen[c['key']] = true
      # срок в списке — прикидка (список отдаётся из кеша): точный срок — со страницы лота
      kind == :active ? (c['left'] || c['closed_day'].to_i + 12 * 3600).to_i > Time.now.to_i : true
    end
  end

  def ba_detail(html)
    # в разметке площадки перед атрибутами бывает перенос строки: «<th⏎class=…>»
    rows = html.scan(%r{<th\s+class=gold_thing_th>(.*?)</th>\s*<th\s+class=norm_thing_th>(.*?)</th>}m).map { |k, v| [txt(k), txt(v)] }
               .reject { |_, v| v.empty? || v =~ /\A\*+\z/ }
    desc = txt(html[%r{box_title>Описание</div>\s*<div\s+class="padd10 the-content-text">(.*?)</div>}m, 1])
    desc = desc.sub(/\s*Итоговая цена выигранного лота.*\z/im, '')
    info = %w[Резервная\ цена Расположение Открытие\ торгов Завершение\ торгов].map do |k|
      [k, txt(html[/#{k}:<\/div>\s*<div[^>]*>(.*?)<\/div>/m, 1])]
    end.reject { |_, v| v.empty? }
    secs = [{ 'h' => 'Условия торгов', 'rows' => info }]
    secs << { 'h' => 'Характеристики', 'rows' => rows } unless rows.empty?
    secs << { 'h' => 'Сведения о лоте', 'rows' => [['Описание', desc]] } unless desc.empty?
    region = info.to_h['Расположение'].to_s
    region = 'г. Минск' if region == 'Минск'
    # где стоит: «Автомобиль находится на площадке филиала … в г. Молодечно, ул. Великосельская, 38»
    place = desc[/наход\S+[^.]{0,120}?((?:г\.|аг\.|д\.)\s*[А-ЯЁ][а-яё-]+(?:,\s*(?:ул|пр-т|пр|пер|тракт|ш)\.?\s*[А-ЯЁа-яё0-9 -]+?(?:,\s*\d+[а-яА-Я]?(?:\/\d+)?)?(?=[.;]|\s*$))?)/, 1]
    ending = html[/id=ending[^>]*>\s*(\d{9,})/, 1].to_i
    end_t = ending.positive? ? ending : ru_date(info.to_h['Завершение торгов'])
    pic = html[%r{(https://belauction\.by/wp-content/uploads/\d{4}/\d{2}/[^\s"'>]+?\.(?:jpe?g|png|webp))}i, 1]
    { 'details' => secs, 'location' => place ? [region.sub(/\Aг\. Минск\z/, ''), place].reject(&:empty?).join(', ') : region,
      'req_to' => end_t, 'torg' => end_t, 'price_byn' => num(txt(html[/id=content-bid>(.*?)<\/p>/m, 1])),
      'photo_url' => pic && pic !~ /slide|flag/ ? pic : nil, 'photos' => photos('belauction.by', html),
      'terms' => { 'vat' => desc =~ /с учетом 20% НДС/i ? 'Для юрлиц текущая ставка — с НДС 20%' : nil,
                   'fee_later' => true, 'v' => 2 }.compact }
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
      STDERR.puts "извещение не разобрано: #{url} (#{t.size} зн.): #{t[0, 400]}" unless n['torg']
      n
  end
  end

  def kf_detail(html, card = {})
    secs = []
    tk = html[%r{href="(https?://torgikonfiskat\.by/[a-z-]*auction/\d+/?)"}, 1]   # сами торги — на torgikonfiskat.by
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
            # часть извещений — сканы без текста: тогда срок выведен по правилу организатора, так и пишем
            ['Приём заявок до', req && Time.at(req).strftime('%d.%m.%Y %H:%M') +
              (n['req_to'] ? '' : ' — по правилу организатора (12:00 накануне аукциона), уточните в извещении')],
            ['Задаток', "#{(n['deposit_pct'] || 10).to_s.sub(/\.0\z/, '')}% от начальной цены"],
            ['Извещение', pdf && KF + pdf]].select { |_, v| v }
    secs.unshift({ 'h' => 'Условия торгов', 'rows' => cond })
    pics = html.scan(%r{src="(/upload/(?:avto|iblock|resize_cache)[^"]+\.(?:jpg|jpeg|png))"}i).flatten.uniq
    owner = extra[/Находится в собственности\s+([^.]+)/, 1]
    { 'details' => secs, 'req_to' => req, 'torg' => torg,
      'location' => n['city'] ? "г. #{n['city']}" : nil, 'debtor' => owner ? owner.strip : 'Конфискованное имущество',
      'photo_url' => pics.first && KF + pics.first, 'photos' => photos('konfiskat.by', html),
      'tk' => tk && tk.sub('http://', 'https://'),
      'terms' => { 'deposit' => card['price'].to_f * (n['deposit_pct'] || 10) / 100, 'fee_later' => true,
                   'pay_term' => n['pay'], 'v' => 2 }.reject { |_, v| v.nil? || v == 0.0 } }
  end

end
