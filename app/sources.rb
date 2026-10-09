# encoding: utf-8
#
# Разбор площадок: e-auction.by, ipmtorgi.by, beltorgi.by, konfiskat.by (торги — на torgikonfiskat.by), belauction.by,
# auction24.by, minskestate.by, lotsale.by, butb.by (et.butb.by) (очные аукционы МГЦН — mgcn.rb).
# Для каждой — список активных карточек раздела, разбор страницы лота и список завершённых торгов (архив).
# cpo.by (ЦПО) с 25.09.2026 не собираем: это рекламная витрина торгов ИПМ.
# Карточка списка: key, platform, art, name, price, req_to, url, thumb (+ служебные поля).
# Страница лота: details (секции «ключ — значение»), location, debtor, area, torg, photo.
require 'json'
require 'time'
require 'tmpdir'
require 'uri'
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

  # curl только по http(s), и после переадресации тоже (адрес из чужой страницы не прочитает file:// и не уйдёт на ftp://),
  # страница — не больше 20 МБ
  CURL = %w[curl -sS -L --proto =http,https --proto-redir =http,https --max-filesize 20000000].freeze

  # короче min — сбой, пробуем ещё раз; для маленьких служебных ответов (окно «все ставки») — get(url, min: 1, tries: 1)
  def get(url, min: 1500, tries: 2)
    return nil unless url.to_s =~ %r{\Ahttps?://}i
    tries.times do |i|
      out = IO.popen([*CURL, '-m', '40', '-A', UA, url], err: File::NULL, &:read)
      out = out.to_s.force_encoding('UTF-8')
      return out if out.size >= min
      sleep 2 if i < tries - 1
    end
    nil
  end

  # Текст из куска HTML. Комментарии, скрипты и стили — прочь (29.09: в описания konfiskat попадали закомментированная
  # вёрстка «-->» и служебный код сайта «BX.message({…})»); коды символов (&#40; &#x28;) — в символы.
  def txt(s)
    decode(s.to_s.gsub(/<!--.*?-->/m, ' ').gsub(%r{<(script|style)\b.*?</\1>}mi, ' ')
     .gsub(/<button.*?<\/button>/m, ' ').gsub(/<br\s*\/?>|<\/p>/i, ' ').gsub(/<[^>]*>/, ' ').gsub(/<!--|-->/, ' '))
     .gsub(/\s+/, ' ').strip
  end

  def decode(s)
    s.to_s.gsub('&nbsp;', ' ').gsub('&quot;', '"').gsub('&laquo;', '«').gsub('&raquo;', '»').gsub('&mdash;', '—').gsub('&ndash;', '–').gsub('&lt;', '<').gsub('&gt;', '>').gsub('&apos;', "'")
     .gsub(/&#(\d{2,5});/) { $1.to_i.chr(Encoding::UTF_8) rescue ' ' }.gsub(/&#x([0-9a-f]{2,4});/i) { $1.hex.chr(Encoding::UTF_8) rescue ' ' }
     .gsub('&amp;', '&')
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
           when 'auction24.by'
             h.scan(%r{class="gallery-link" href="(/file/[^"]+)"}).flatten.map { |u| A24 + u }
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
    (1..(since ? 400 : MAX_PAGES)).each do |p|
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
    (1..(since ? 300 : MAX_PAGES)).each do |p|
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
  # stop — время, после которого не листаем (за год — ~1 200 страниц, 40 минут)
  def tk_archive(since, stop = nil)
    out = []
    seen = {}
    now = Time.now.to_i
    %w[80%7C81 ARCHIVE].each do |st|
      (1..2000).each do |p|
        break if stop && Time.now > stop
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
  # nil — список не прочитан; [] — раздел пуст: площадка так и пишет «Ничего не найдено»
  # (05.10: «Собственное имущество» пусто с 25.09 — сигнализация несколько дней считала это сбоем)
  def kf_list(path)
    out = []
    seen = {}
    (1..MAX_PAGES).each do |p|
      html = get("#{KF}/#{path}/" + (p > 1 ? "?PAGEN_1=#{p}" : ''))
      return nil if !html && p == 1
      break unless html
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
      return nil if got.empty? && p == 1 && !html.include?('Ничего не найдено')
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
      system(*CURL, '-m', '60', '-A', UA, '-o', tmp, url, out: File::NULL, err: File::NULL) if url.to_s =~ %r{\Ahttps?://}i
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
    # 29.09 konfiskat сменил вёрстку: «<h2>Дополнительная информация:</h2><p itemprop="description">…» — старое правило
    # не находило конец и тянуло страницу до конца (характеристики ещё раз, вёрстку, код сайта)
    extra = txt(html[/itemprop="description"[^>]*>(.*?)<\/div>/m, 1] || html[/Дополнительная информация:\s*<\/(?:p|h2|h3)>(.*?)<\/div>/m, 1])
    extra = extra.sub(/\s*\.?\s*Аукцион проводится на электронной торговой площадке.*\z/m, '')   # общий текст про аукцион — у всех лотов одинаковый
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

  # ---------------- auction24.by (ЭТП ООО «Госторги») ----------------
  # Имущество райпо и потребкооперации по всем областям: магазины, кафе, торговые объекты, оборудование; есть торги
  # на право аренды (торгуются за ежемесячную арендную плату) и торги на понижение. robots.txt закрывает только кабинет.
  # Каталог по статусу: /catalog/<раздел>/accept — приём заявок; страницы ?page=0,1… (с нуля), до 100 лотов (&limit=100).
  # Архив — по списку аукционов /auction (от поздних к ранним): страница аукциона — лоты со статусом.
  A24 = 'https://auction24.by'
  # раздел площадки → наш; 3 «Транспорт и запчасти» — легковой или грузовой по названию; 8 «Дебиторская задолженность» не берём
  A24_SEC = { 2 => 'nedvizhimost', 3 => 'auto', 10 => 'spec', 7 => 'oborud', 9 => 'oborud' }.freeze

  # раздел по названию: право аренды → «Право аренды»; транспорт — легковой или грузовой; для архива (раздела нет) — недвижимость по признакам
  def a24_sec(name, cat_sec = nil)
    n = name.to_s.downcase
    return 'arenda' if n =~ /права на заключение договора аренды|право аренды/
    sec = cat_sec || (n =~ /капитальн|строени|здани|помещени|магазин|кафе|склад|незаверш|квартир|жилой дом|земельн|гараж/ ? 'nedvizhimost'
                     : n =~ /автомоб|автобус|прицеп|тягач|самосвал|фургон/ ? 'auto' : n =~ /трактор|погрузчик|экскаватор|комбайн|кран/ ? 'spec' : 'oborud')
    sec == 'auto' ? (n =~ /груз|тягач|самосвал|автобус|прицеп|фургон|цистерн|бортов/ ? 'gruz' : 'avto') : sec
  end

  # карточки каталога или страницы аукциона: «Лот 9867 <название> начальная цена 190 000.00 BYN … Прием заявок до …»
  def a24_cards(html, csec = nil)
    html.split('class="product-card-wrap"').drop(1).map do |ch|
      id = ch[%r{/auction/lot/(\d+)}, 1] or next
      t = txt(ch[0, 6000])
      name = txt(ch[/<img[^>]+alt="([^"]+)"/, 1].to_s)
      name = t[/Лот \d+\s+(.+?)\s+начальная цена/, 1].to_s if name.empty?
      { 'key' => "a24-#{id}", 'platform' => 'auction24.by', 'art' => id, 'name' => name, 'sec' => a24_sec(name, csec),
        'url' => "#{A24}/auction/lot/#{id}", 'price' => num(t[/начальная цена\s+([\d\s.]+)\s*BYN/, 1]),
        'status' => txt(ch[%r{class="sticker[^"]*">(.*?)</span>}m, 1]),
        'req_to' => ts(t[/Прием заявок до\s+(\d{2}\.\d{2}\.\d{4}\s+\d{1,2}:\d{2})/, 1]),
        'thumb' => (u = ch[%r{src="(/file/[^"]+)"}, 1]) && A24 + u }
    end.compact
  end

  def a24_list
    A24_SEC.flat_map do |cat, csec|
      out = []
      (0..20).each do |p|
        html = get("#{A24}/catalog/#{cat}/accept?page=#{p}&limit=100") or break
        sleep 1
        cards = a24_cards(html, csec)
        out.concat(cards)
        break if cards.size < 100
      end
      out
    end.uniq { |c| c['key'] }
  end

  # архив: аукционы с датой после since (список /auction — от поздних к ранним), их завершённые лоты
  def a24_done(since)
    html = get("#{A24}/auction") or return []
    aucs = html.split(%r{href="/auction/(?=\d+")}).drop(1).map do |ch|
      d = ch[/Аукцион (\d{2}\.\d{2}\.\d{4})/, 1] or next
      [ch[/\A\d+/], ts("#{d} 12:00")]
    end.compact.uniq(&:first)
    aucs.select { |_, d| d && d >= since && d < Time.now.to_i }.flat_map do |id, _|
      sleep 1
      (h = get("#{A24}/auction/#{id}")) ? a24_cards(h).select { |c| c['status'] =~ /продан|не состоял|отмен/i } : []
    end.uniq { |c| c['key'] }
  end

  def a24_detail(html)
    f = html.scan(%r{<tr><td>(.*?)</td><td>(.*?)</td>}m).map { |k, v| [txt(k), txt(v)] }.to_h
    tab = ->(id) { html[%r{id="#{id}" role="tabpanel"[^>]*>(.*?)(?:<div class="tab-pane|\z)}m, 1].to_s }
    des = txt(tab.('des'))
    desc = des[/Описание\s+(.+?)(?:\s+Расположение имущества|\s*\*{5}|\z)/, 1].to_s.strip
    place = des[/Расположение имущества\s+(.+?)(?:\s+-->|\s+Продавец|\s+Прикрепленные|\s+Фото документов|\s*\*{5}|\z)/, 1].to_s.strip
    osm = txt(tab.('osm'))
    seller = osm[/Наименование:\s*(.+?)\s+Адрес:/, 1]
    cond = ['Лот №', 'Метод аукциона', 'Очередность', 'Снижение начальной цены', 'Начальная цена', 'Минимальная цена', 'Шаг торгов',
            'Сумма задатка', 'Дата и время окончания приема заявок', 'Дата и время начала торгов', 'Дата и время завершения торгов',
            'Сумма затрат на организацию и проведение торгов', 'Вознаграждение организатору торгов (аукционный сбор)',
            'Срок для возмещения затрат и вознаграждения оператору ЭТП', 'Срок заключения договора', 'Срок оплаты по договору']
    secs = [{ 'h' => 'Условия торгов', 'rows' => cond.map { |k| [k, f[k]] }.select { |_, v| v && !v.empty? } }]
    secs << { 'h' => 'Сведения о лоте', 'rows' => [['Описание', desc], ['Расположение имущества', place]].reject { |_, v| v.empty? } }
    secs << { 'h' => 'Продавец и осмотр', 'rows' => [['Осмотр и продавец', osm[0, 800]]] } unless osm.empty?
    pics = photos('auction24.by', html)
    price = num(f['Начальная цена'].to_s[/[\d\s.]+/])
    min = num(f['Минимальная цена'].to_s[/[\d\s.]+/])
    # «Начальная цена (размер ежемесячной арендной платы) …» и «Начальная цена (размер) ежемесячной арендной платы …»
    rent = desc[/Начальная цена[^.]{0,40}ежемесячной арендной платы.*?НДС\s*\d+\s*%/]
    { 'details' => secs.reject { |s| s['rows'].empty? }, 'location' => place.empty? ? nil : place, 'debtor' => seller,
      'req_to' => ts(f['Дата и время окончания приема заявок']), 'torg' => ts(f['Дата и время начала торгов']),
      'price_byn' => price, 'area_num' => (a = desc[/пл(?:ощадью|\.)\s*([\d\s]+[.,]?\d*)\s*кв\.?\s*м/, 1]) && num(a),
      'photo_url' => pics.first, 'photos' => pics, 'status' => f['Статус'],
      'rent' => rent && { 'k' => 'month', 'v' => price, 'raw' => rent.strip },
      'terms' => { 'deposit' => num(f['Сумма задатка'].to_s[/[\d\s.]+/]), 'step_abs' => num(f['Шаг торгов'].to_s[/[\d\s.]+/]),
                   'fee_abs' => num(f['Сумма затрат на организацию и проведение торгов'].to_s[/[\d\s.]+/]),
                   'fee_pct' => f['Вознаграждение организатору торгов (аукционный сбор)'].to_s[/[\d.,]+/]&.tr(',', '.')&.to_f,
                   'min_price' => min.positive? && min < price ? min : nil,
                   'vat' => f['Начальная цена'].to_s =~ /НДС 20/ ? 'Начальная цена — с НДС 20%' : nil, 'v' => 2 }
                 .reject { |_, v| v.nil? || v == 0.0 } }
  end

  # ---------------- minskestate.by (ЭТП «Минск-Недвижимость» государственного предприятия «МГЦН») ----------------
  # Электронные торги недвижимостью Минска. Список раздела — одна страница со всеми лотами, и активными, и
  # завершёнными (статус в карточке: «Приём заявок», «Продано», «Торги не состоялись»…). robots.txt закрывает
  # адреса с «?», «%» и «product»: листать и фильтровать списки не нужно, фото (…/img_products/…) не скачиваем —
  # сайт показывает их ссылками, как галереи других площадок.
  # Ключ — номер аукциона латиницей («Ч-2026.10.366» → me-ch-2026.10.366): у повторных торгов номер новый.
  ME = 'https://minskestate.by'
  ME_SEC = { 'nedvizhimost-v-sobstvennost' => 'nedvizhimost', 'kvartiry-i-zhilye-doma' => 'nedvizhimost',
             'nedvizhimost-v-arendu' => 'arenda', 'transport-i-spetstekhnika' => nil, 'oborudovanie' => 'oborud' }.freeze   # nil — по названию
  LAT = { 'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e', 'ж' => 'zh', 'з' => 'z', 'и' => 'i', 'й' => 'j',
          'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's', 'т' => 't', 'у' => 'u',
          'ф' => 'f', 'х' => 'h', 'ц' => 'c', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'sch', 'ы' => 'y', 'э' => 'e', 'ю' => 'yu', 'я' => 'ya' }.freeze

  def me_key(no)
    'me-' + no.to_s.downcase.gsub(/[а-я]/) { |c| LAT[c] || '' }.gsub(/[^a-z0-9.-]/, '')
  end

  def me_list
    ME_SEC.flat_map do |cat, sec|
      html = get("#{ME}/commerce/#{cat}") or next []
      sleep 1
      html.split('blockProductItemLot').drop(1).map do |ch|
        ch = ch[0, 6000]
        href = ch[%r{href="(/commerce/#{cat}/[^"]+)"}, 1] or next
        no = txt(ch[%r{Аукцион №:\s*<b>(.*?)</b>}m, 1])
        next if no.empty?
        { 'key' => me_key(no), 'platform' => 'minskestate.by', 'art' => no, 'sec' => sec, 'url' => ME + href,
          'name' => decode(ch[/moduleProductName">\s*<a [^>]*title="([^"]+)"/, 1].to_s).strip,
          'status' => txt(ch[%r{listLotStatus">(.*?)</div>}m, 1]), 'price' => num(txt(ch[%r{listAuctionActualPrice">(.*?)</div>}m, 1])),
          'day' => ts(txt(ch[%r{Дата аукциона:\s*<b>(.*?)</b>}m, 1]) + ' 12:00'),
          'phx' => ch[%r{src="(https://minskestate\.by/components/com_jshopping/files/img_products/[^"]+)"}, 1] }
      end.compact
    end
  end

  def me_detail(html)
    f = html.scan(%r{productCustomFieldName"><span>(.*?)</span></div>\s*<div class="productCustomFieldVal">(.*?)</div>}m)
            .map { |k, v| [txt(k), txt(v)] }.to_h
    desc = txt(html[%r{id="tab_description"[^>]*>(.*?)<div class="tab-pane}m, 1])
    seller = html[%r{id="tab_description3"[^>]*>(.*?)</div>\s*</div>}m, 1].to_s.scan(%r{productParamItem">(.*?)</div>}m)
                 .map { |(x)| txt(x).split(/:\s*/, 2) }.select { |x| x.size == 2 && !x[1].empty? }
    org = html[%r{id="tab_description4"[^>]*>(.*?)</div>\s*</div>}m, 1].to_s.scan(%r{productParamItem">(.*?)</div>}m)
              .map { |(x)| txt(x).split(/:\s*/, 2) }.select { |x| x.size == 2 && !x[1].empty? && x[0] != 'Реквизиты' }
    cond = ['Аукцион №', 'Начальная цена', 'Шаг торгов', 'Размер задатка', 'Начало приема заявок', 'Окончание приема заявок',
            'Начало торгов', 'Ориентировочная сумма затрат на организацию и проведение торгов', 'Вознаграждение организатору торгов',
            'Срок для возмещения затрат и (или) вознаграждения', 'Срок заключения договора', 'Срок оплаты по договору']
    secs = [{ 'h' => 'Условия торгов', 'rows' => cond.map { |k| [k, f[k]] }.select { |_, v| v && !v.empty? } }]
    secs << { 'h' => 'Сведения о лоте', 'rows' => [['Описание', desc]] } unless desc.empty?
    secs << { 'h' => 'Продавец', 'rows' => seller } unless seller.empty?
    secs << { 'h' => 'Организатор торгов', 'rows' => org } unless org.empty?
    pics = html.scan(%r{(https://minskestate\.by/components/com_jshopping/files/img_products/[^"'\s]*/full_[^"'\s]+\.(?:jpe?g|png|webp))}i).flatten.uniq
    step = f['Шаг торгов'].to_s
    { 'details' => secs, 'location' => txt(html[%r{Местонахождение лота:</span>\s*<span[^>]*>(.*?)</span>}m, 1]),
      'req_to' => ts(f['Окончание приема заявок']), 'torg' => ts(f['Начало торгов']),
      'debtor' => (seller.assoc('Продавец') || [])[1], 'price_byn' => num(f['Начальная цена'].to_s[/[\d\s.,]+/]),
      'area_num' => (a = desc[/площадью\s+([\d\s]+[.,]?\d*)\s*кв\.?\s*м/, 1]) && num(a),
      'photos' => pics, 'status' => f['Статус'],
      'terms' => { 'deposit' => num(f['Размер задатка'].to_s[/[\d\s.,]+/]), 'step_pct' => step[/\(([\d.,]+)%\)/, 1]&.tr(',', '.')&.to_f,
                   'fee_abs' => num(f['Ориентировочная сумма затрат на организацию и проведение торгов'].to_s[/[\d\s.,]+/]),
                   'fee_pct' => f['Вознаграждение организатору торгов'].to_s[/[\d.,]+/]&.tr(',', '.')&.to_f,
                   'vat' => f['Начальная цена'].to_s =~ /без НДС/ ? 'Начальная цена указана без НДС' : nil, 'v' => 2 }
                 .reject { |k, v| v.nil? || (v == 0.0 && k != 'fee_pct') } }
  end

  # ---------------- lotsale.by (ЭТП LotSale) ----------------
  # Сайт — приложение на JS, лоты берёт из открытого API api.lotsale.by (JSON; robots.txt закрывает лишь несколько
  # старых аукционов, у API его нет). Лотов мало — обычно 0–15 активных: техника и госимущество организаций.
  # Активные — /auctions/public (все сразу), лот — /auctions/<id>/public (условия, ставки, итог), имущество лота —
  # /property/<id> (адрес и все фото). Завершённые — /auctions/public/completed, от поздних к ранним.
  # Пустой список — не сбой: у площадки по нескольку дней нет торгов (сбой — когда API не ответил: nil).
  LS = 'https://lotsale.by'
  LS_API = 'https://api.lotsale.by'
  LS_TYPE = { 'BaseAuction' => 'Аукцион', 'DownwardAuction' => 'Аукцион со снижением цены', 'StatePropertyAuction' => 'Продажа госимущества' }.freeze

  def ls_json(path)
    out = get(LS_API + path, min: 2) or return nil
    JSON.parse(out)
  rescue JSON::ParserError
    nil
  end

  def ls_t(s)
    s ? Time.parse(s).to_i : nil
  end

  # ссылка как у самой площадки: /auction/<id>/<название латиницей через дефис>
  def ls_url(id, name)
    slug = name.to_s.strip.downcase.gsub(/[а-яё]/) { |c| c == 'ё' ? 'yo' : c == 'щ' ? 'shh' : (LAT[c] || '') }
               .gsub(%r{[\\/]}, '').gsub(/\s+/, '-').gsub(/[^a-z0-9.()\-]/) { |c| format('%%%02X', c.ord) if c.ord < 128 }
    "#{LS}/auction/#{id}/#{slug}"
  end

  # раздел: 1 «Недвижимость», 2 «Транспорт и запчасти» — по названию, остальное (оборудование, мебель, техника…) — оборудование
  def ls_sec(cat, name)
    return 'nedvizhimost' if cat == 1
    return 'oborud' unless cat == 2
    n = name.to_s.downcase
    return 'spec' if n =~ /трактор|погрузчик|экскаватор|грейдер|бульдозер|комбайн|кран|каток|john deere|claas|мтз|беларус/
    n =~ /груз|автобус|тягач|самосвал|прицеп|фургон|цистерн|бортов|маз|камаз|зил|краз/ ? 'gruz' : 'avto'
  end

  # лот целиком: аукцион + имущество; подробности готовы сразу (как у МГЦН — c['d'])
  def ls_lot(id)
    a = ls_json("/auctions/#{id}/public") or return nil
    lot = a['lot'] || {}
    pr = (lot['property'] || [])[0] || {}
    sleep 0.5
    prop = pr['id'] ? ls_json("/property/#{pr['id']}") || {} : {}
    name = lot['name'].to_s.gsub(/\s+/, ' ').strip
    loc = [pr.dig('region', 'name'), prop['Address'].to_s.strip].reject { |x| x.to_s.empty? }.join(', ')
    desc = lot['description'].to_s.gsub(/\s+/, ' ').strip
    pics = (prop['PropertyImages'] || []).sort_by { |i| i['IsFirst'] ? 0 : 1 }.map { |i| i['Url'] }.compact
    pics = [pr.dig('image', 'url')].compact if pics.empty?
    dt = ->(s) { (t = ls_t(s)) && Time.at(t).strftime('%d.%m.%Y %H:%M') }
    byn = ->(v) { v.to_f.positive? ? format('%.2f', v).sub(/\A\d+/) { |i| i.reverse.scan(/\d{1,3}/).join(' ').reverse }.sub('.', ',') + ' BYN' : nil }
    terms = lot['dealTerms'] || {}
    init = lot['initialPrice'].to_f
    min = lot['minimalPrice'].to_f
    cond = [['Вид торгов', LS_TYPE[a['auctionType']]], ['Начальная цена', byn.(init)],
            ['Минимальная цена', min.positive? && min < init ? byn.(min) : nil], ['Шаг торгов', byn.(a['step'])],
            ['Задаток', byn.(a['deposit'])], ['Приём заявок с', dt.(a['applicationStartDateOnUtc'])],
            ['Приём заявок до', dt.(a['applicationDeadlineOnUtc'])], ['Начало торгов', dt.(a['dateStartOnUtc'])],
            ['Окончание торгов', dt.(a['dateFinishOnUtc'])],
            ['Срок возмещения затрат, дней', terms['reimbursementTerm']], ['Срок заключения договора, дней', terms['contractTerm']],
            ['Срок оплаты, дней', terms['paymentTerm']], ['Условия', terms['moreDetails'].to_s.gsub(/\s+/, ' ').strip]]
    cat = [pr.dig('category', 'name'), pr.dig('subCategory', 'name')].compact.join(' / ')
    org = a['organizer'] || {}
    secs = [{ 'h' => 'Условия торгов', 'rows' => cond.map { |k, v| [k, v.to_s] }.reject { |_, v| v.empty? } },
            { 'h' => 'Сведения о лоте', 'rows' => [['Описание', desc], ['Местонахождение', loc], ['Категория', cat]].reject { |_, v| v.empty? } },
            { 'h' => 'Организатор торгов', 'rows' => [['Наименование', org['name']], ['Адрес', org['address']], ['Телефон', org['contacts']]]
                .map { |k, v| [k, v.to_s.strip] }.reject { |_, v| v.empty? } }]
    { 'a' => a, 'name' => name, 'sec' => ls_sec(pr.dig('category', 'id'), name),
      'details' => secs.reject { |s| s['rows'].empty? }, 'location' => loc.empty? ? nil : loc,
      'debtor' => (lot.dig('owner', 'name') || org['name']).to_s.strip, 'req_to' => ls_t(a['applicationDeadlineOnUtc']),
      'torg' => ls_t(a['dateStartOnUtc']), 'price_byn' => init,
      'area_num' => (x = desc[/площадью\s+([\d\s]+[.,]?\d*)\s*кв\.?\s*м/, 1]) && num(x),
      'photo_url' => pics.first, 'photos' => pics,
      'terms' => { 'deposit' => a['deposit'].to_f, 'step_abs' => a['step'].to_f, 'min_price' => min.positive? && min < init ? min : nil,
                   'pay_term' => terms['paymentTerm'] && "#{terms['paymentTerm']} дней", 'fee_later' => true, 'v' => 2 }
                 .reject { |_, v| v.nil? || v == 0.0 } }
  end

  # карточка — из строки списка; подробности (d) — если страница лота ответила (нет — лот всё равно «виден» в списке)
  def ls_card(i, d)
    name = i['lotName'].to_s.gsub(/\s+/, ' ').strip
    { 'key' => "ls-#{i['id']}", 'platform' => 'lotsale.by', 'art' => i['id'].to_s, 'name' => name, 'sec' => d && d['sec'],
      'url' => ls_url(i['id'], name), 'price' => i['price'].to_f, 'req_to' => ls_t(i['applicationDeadlineOnUtc']),
      'thumb' => i.dig('lotImage', 'url'), 'd' => d }
  end

  # активные лоты: nil — API не ответил, [] — торгов сейчас нет
  def ls_list
    items = []
    (1..10).each do |p|
      j = ls_json("/auctions/public?PageNumber=#{p}&PageSize=100") or return nil
      page = j.dig('data', 'items') or return nil
      items.concat(page)
      break unless j.dig('data', 'hasNext')
    end
    items.uniq { |i| i['id'] }.map do |i|
      sleep 0.5
      ls_card(i, ls_lot(i['id']))
    end
  end

  # архив: завершённые торги с окончанием после since — [id, …]
  def ls_done(since)
    out = []
    (1..60).each do |p|
      j = ls_json("/auctions/public/completed?PageNumber=#{p}&PageSize=100") or break
      items = j.dig('data', 'items') || []
      fresh = items.select { |i| ls_t(i['dateFinishOnUtc']).to_i >= since }
      out.concat(fresh.map { |i| i['id'] })
      break if fresh.size < items.size || !j.dig('data', 'hasNext')
      sleep 0.5
    end
    out.uniq
  end

  # ---------------- butb.by (ЭТП «БУТБ-Имущество» Белорусской универсальной товарной биржи, et.butb.by) ----------------
  # Госимущество: облимущества и райисполкомы продают здания, «неиспользуемые объекты» (часто за 1 базовую величину),
  # технику; есть торги на право аренды. robots.txt у площадки нет. Сайт на JSF: список «Торги» показывает по 10 лотов,
  # остальные — через запрос пагинатора; ему можно сказать «все на одной странице» (rows=600) — весь список за 2 запроса.
  # Архив торгов (archiveAuctions.xhtml, ≈ 14,7 тыс. с 2016 г.) устроен так же, от поздних торгов к ранним.
  # Лот — lotcard.xhtml?lotid=<id>: «Состояние лота», сроки, цены, панели «Сведения о предмете торгов» и др.
  # Фото — во временной папке tmp_files/, которую площадка создаёт при открытии карточки: главное фото скачиваем сразу,
  # галерею ссылками не храним (ссылки со временем перестают открываться). Повторные торги — новый lotid.
  BU = 'https://et.butb.by'

  # таблица лотов страницы (auctions.xhtml или archiveAuctions.xhtml): page — номер страницы по rows лотов
  def bu_table(path, rows, page = 1)
    Dir.mktmpdir do |dir|
      jar = File.join(dir, 'c')
      h = IO.popen([*CURL, '-m', '60', '-A', UA, '-c', jar, '-b', jar, "#{BU}/et/#{path}"], err: File::NULL, &:read).to_s.force_encoding('UTF-8')
      f = h[/<form[^>]*id="f_lots".*?<\/form>/m] or return nil
      act = f[/action="([^"]+)"/, 1] or return nil
      vs = h[/name="javax\.faces\.ViewState"[^>]*value="([^"]*)"/, 1] or return nil
      form = { 'f_lots' => 'f_lots', 'javax.faces.ViewState' => vs, 'javax.faces.source' => 'f_lots:tableLot',
               'javax.faces.partial.execute' => 'f_lots:tableLot', 'javax.faces.partial.render' => 'f_lots:tableLot',
               'javax.faces.partial.ajax' => 'true', 'f_lots:tableLot_paging' => 'true',
               'f_lots:tableLot_rows' => rows.to_s, 'f_lots:tableLot_page' => page.to_s }
      out = IO.popen([*CURL, '-m', '120', '-A', UA, '-c', jar, '-b', jar, '-H', 'Faces-Request: partial/ajax',
                      '-H', "Referer: #{BU}/et/#{path}", '--data-raw', URI.encode_www_form(form), BU + decode(act)],
                     err: File::NULL, &:read).to_s.force_encoding('UTF-8')
      out.include?('lotid=') ? out : (out =~ /partial-response/ ? '' : nil)   # пустая таблица — '', сбой — nil
    end
  end

  def bu_cards(html)
    html.split(/<div class="lot-item(?: lot-item-arch)?">/).drop(1).map do |ch|   # в архиве карточка — «lot-item lot-item-arch»
      id = ch[/lotcard\.xhtml[^"]*?lotid=(\d+)/, 1] or next
      box = ->(t) { txt(ch[%r{lot-item-title">\s*#{t}\s*</div>\s*<div class="info-block-value2?">(.*?)</div>}m, 1]) }
      name = txt(ch[%r{class="lot-name"[^>]*>(.*?)</span>}m, 1])
      { 'key' => "bu-#{id}", 'platform' => 'butb.by', 'art' => txt(ch[/Торги №\s*([A-ZА-Я]?\d+)/, 1]), 'name' => name,
        'url' => "#{BU}/et/lotcard.xhtml?lotid=#{id}", 'status' => txt(ch[%r{class="lot-status\d*">(.*?)</div>}m, 1]),
        'price' => num(box.('Начальная цена')), 'sold' => num(box.('Цена продажи')),
        'req_to' => ts(box.('Окончание приема заявлений')), 'day' => ts(box.('Дата и время торгов')),
        # раздел по названию — предварительно (точный — по категории в карточке лота); у биржи почти всё — недвижимость,
        # поэтому «непонятное» не считаем оборудованием: иначе порог цены оборудования отсеял бы здания за 1 базовую величину
        'sec' => (s = a24_sec(name)) == 'oborud' ? 'nedvizhimost' : s,
        'thumb' => (u = ch[/<img src="(tmp_files\/[^"]+)"/, 1]) && "#{BU}/et/#{u}" }
    end.compact.uniq { |c| c['key'] }
  end

  # активные: весь список «Торги» одной страницей; nil — не прочитан
  def bu_list
    html = bu_table('auctions.xhtml', 600) or return nil
    bu_cards(html)
  end

  # архив: завершённые торги с датой после since (страницы по 100, от поздних к ранним)
  def bu_done(since, stop = nil)
    out = []
    (1..200).each do |p|
      break if stop && Time.now > stop
      html = bu_table('archiveAuctions.xhtml', 100, p) or break
      cards = bu_cards(html)
      fresh = cards.select { |c| c['day'].to_i >= since }
      out.concat(fresh)
      break if cards.empty? || fresh.empty?
      sleep 1
    end
    out.uniq { |c| c['key'] }
  end

  # раздел по «Категории предмета торгов» — только первая часть до «/» (дальше бывает «…с предоставлением земельного участка
  # в аренду» и у зданий); движимое имущество — по названию
  def bu_sec(cat, name)
    c = cat.to_s.split('/').first.to_s.downcase
    return 'arenda' if c =~ /аренд/
    return 'nedvizhimost' if c =~ /недвижим|земельн|жилые дома|строительств|доля/
    s = a24_sec(name)
    s == 'nedvizhimost' ? 'oborud' : s
  end

  def bu_detail(html)
    top = html.scan(%r{lot-block-text">(.*?)</div>\s*<span class="lot-block-value[^"]*"[^>]*>(.*?)</span>}m).map { |k, v| [txt(k), txt(v)] }.to_h
    secs = html.split('class="ui-panel-title">').drop(1).map do |p|
      h = txt(p[/\A(.*?)</m, 1])
      rows = p.split('<div class="param-item">').drop(1).map do |it|
        k = txt(it[%r{class="param-name[^"]*"[^>]*>(.*?)</span>}m, 1])
        v = txt(it.sub(%r{.*?class="param-name[^"]*"[^>]*>.*?</span>}m, '').split(/<div class="ui-panel|<span class="ui-panel-title/)[0])
        [k, v]
      end.reject { |k, v| k.empty? || v.empty? || k =~ /Расчетный счет|Валюта счета|^Банк$|Адрес банка|Назначение платежа|Бенефициар/ }
      { 'h' => h, 'rows' => rows }
    end.reject { |s| s['rows'].empty? || s['h'] =~ /Банковские реквизиты/ }
    f = secs.flat_map { |s| s['rows'] }.to_h
    find = ->(re) { (f.find { |k, _| k =~ re } || [])[1] }
    title = txt(html[%r{<h1[^>]*>(.*?)</h1>}m, 1])
    name = find.(/\AНаименование предмета торгов/) || title
    cond = [['Торги №', html[/Торги №\s*([A-ZА-Я]?\d+)/, 1]], ['Состояние лота', top['Состояние лота']],
            ['Приём заявок до', top['Прием заявлений до']], ['Дата и время торгов', top['Дата и время торгов']],
            ['Начальная цена', find.(/\AНачальная цена предмета торгов/)], ['Размер задатка', find.(/\AРазмер задатка/)],
            ['Первый шаг торгов', find.(/\AПервый шаг торгов, бел/)],
            ['Затраты на организацию торгов', find.(/\AИнформация о затратах/)]].reject { |_, v| v.to_s.empty? }
            .map { |k, v| [k, k =~ /цена|задат|шаг|затрат/i && v =~ /\A[\d\s,.]+\z/ ? "#{v} BYN" : v] }
    cond << ['Определение начальной цены', find.(/\AОпределение начальной цены/)] if find.(/\AОпределение начальной цены/)
    secs.unshift({ 'h' => 'Условия торгов', 'rows' => cond })
    # фото этого лота — полноразмерные (у соседних лотов тех же торгов на странице только уменьшенные «_sc»)
    pics = html.scan(%r{(tmp_files/[^"'\s]+\.(?:jpe?g|png|webp))}i).flatten.uniq.reject { |u| u =~ /_sc\.\w+\z/ }.map { |u| "#{BU}/et/#{u}" }
    price = num(find.(/\AНачальная цена предмета торгов/) || top['Начальная цена'])
    # продавец, арендодатель или сельисполком («Наименование местного исполнительного комитета»)
    seller = (find.(/\AНаименование (продавца|арендодателя)/) || find.(/\AНаименование местного исполнительного комитета/)).to_s
    # «аг. Ореховка», «ул. Каменногорская, 104» — без области: добавляем «Район нахождения» («Могилевская область, Кличевский район»)
    loc = find.(/\AМестонахождение предмета торгов/).to_s
    dist = find.(/\AРайон нахождения/).to_s
    loc = [dist, loc].reject(&:empty?).join(', ') if loc !~ /обл|Минск/ && !dist.empty?
    # продавец — без адреса и УНП: «…«Баума». 231345 Гродненская область, …», «…, аг. Гервяты, …», «… (УНП 100364025)»
    seller = seller.sub(/\s*\(?УНП[^)]*\)?\s*\z/, '')
                   .sub(/(?:[,.:]\s*|(?<=[“”»"])\s+)(?:УНП|\d{6}\b|аг\.|г\.|ул\.|д\.|[А-ЯЁ][а-яё]+ск(?:ая|ий)\s+(?:обл|р-н|район)).*\z/m, '').strip
    { 'details' => secs, 'name' => name, 'sec' => bu_sec(find.(/\AКатегория предмета торгов/), name),
      'location' => loc.empty? ? nil : loc, 'debtor' => seller.empty? ? nil : seller,
      'req_to' => ts(top['Прием заявлений до']), 'torg' => ts(top['Дата и время торгов'] || top['Начало торгов']),
      'price_byn' => price, 'area_num' => (a = find.(/\AОбщая площадь/)) && num(a.split(';')[0]),
      'photo_url' => pics.first, 'photos' => [], 'status' => top['Состояние лота'],
      'terms' => { 'deposit' => num(find.(/\AРазмер задатка/)), 'step_abs' => num(find.(/\AПервый шаг торгов, бел/)),
                   'fee_abs' => num(find.(/\AИнформация о затратах/)), 'v' => 2 }.reject { |_, v| v.nil? || v == 0.0 } }
  end

end
