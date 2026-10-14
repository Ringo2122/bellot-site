# encoding: utf-8
#
# Разбор площадок: e-auction.by, ipmtorgi.by, beltorgi.by, konfiskat.by (торги — на torgikonfiskat.by), belauction.by,
# auction24.by, minskestate.by, lotsale.by, butb.by (et.butb.by), gostorg.by (очные аукционы МГЦН — mgcn.rb).
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

  # НДС из текста лота: «может быть увеличена на сумму НДС», «плюс 20% НДС», «без НДС» — к цене может добавиться НДС
  # (в калькуляторе — галочка «+ НДС 20%»); «с учетом НДС» — только пометка. 13.10: раньше у новых площадок НДС не брали
  VAT_ADD = /увелич[а-яё]*\s+на\s+(?:сумму\s+)?(?:\d+\s*%\s*)?НДС|плюс\s*\d+\s*%\s*НДС|НДС,?\s*исчисляем[а-яё]*\s+сверх|без\s+(?:учета\s+)?НДС/i
  def vat_of(tx, with_vat = false)
    return { 'vat' => 'К цене может добавиться НДС 20% - зависит от продавца', 'vat_add' => true } if tx.to_s =~ VAT_ADD
    with_vat || tx.to_s =~ /с\s+учетом\s+(?:\d+\s*%\s*)?НДС|\(с НДС\)|BYN с НДС/i ? { 'vat' => 'Цена указана с НДС' } : {}
  end

  # «22.10.2026г. 16:00», «22.10.2026 | 16:00», «22.10.2026 16:00:00»
  def ts(s)
    m = s.to_s.match(/(\d{2})\.(\d{2})\.(\d{4})\D+(\d{1,2}):(\d{2})/) or return nil
    Time.local(m[3].to_i, m[2].to_i, m[1].to_i, m[4].to_i, m[5].to_i).to_i
  end

  # «28 октября 2026 11:00» → время (etpvit пишет даты на странице лота словами)
  MONTHS = %w[января февраля марта апреля мая июня июля августа сентября октября ноября декабря].freeze
  def ts_words(s)
    m = s.to_s.match(/(\d{1,2})\s+([а-я]+)\s+(\d{4})\D+(\d{1,2}):(\d{2})/) or return nil
    mon = MONTHS.index(m[2]) or return nil
    Time.local(m[3].to_i, mon + 1, m[1].to_i, m[4].to_i, m[5].to_i).to_i
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
           when 'gostorg.by'   # только главный слайдер лота (ниже — фото «похожих лотов»)
             h[/js-auction-card-slider-main(.*?)js-auction-card-slider-nav/m, 1].to_s
               .scan(%r{(?:src|data-src|href)="(/upload/[^"]+\.(?:jpe?g|png|webp))"}i).flatten.map { |u| GS + u }
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
                   'pay_term' => terms['paymentTerm'] && "#{terms['paymentTerm']} дней", 'v' => 3 }
                 .merge(ls_fee(terms['moreDetails'].to_s)).merge(vat_of(desc)).reject { |_, v| v.nil? || v == 0.0 } }
  end

  # сборы — из «Условий» (13.10): «возмещение затрат оператору на проведение торгов 787,23 рублей c НДС» — сумма;
  # «согласно прейскуранту» — шкала lotsale.by/docs/Price.pdf (от цены продажи: 8% до 7 500 руб., 5% до 50 000, 4% до 250 000,
  # 3% до 500 000, 2% до 1 млн, дальше 1% — в калькуляторе сайта). Организатор может уточнить сумму за 12 часов до торгов
  def ls_fee(tx)
    return { 'fee_abs' => num($1) } if tx =~ /затрат оператору на проведение торгов\s*(\d[\d\s]*(?:[.,]\d+)?)\s*руб/i
    tx =~ /прейскурант/i ? { 'fee_scale' => 'lotsale' } : { 'fee_later' => true }
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

  # ---------------- gostorg.by (ЭТП GOSTORG РУП «Институт недвижимости и оценки») ----------------
  # Bitrix. В каталоге три вида продажи (фильтр «Вид продажи»): электронные торги, очные торги и «размещение объявлений»
  # (изучение спроса, ≈ 12 тыс. в недвижимости) — его не берём (решение Артёма 09.10.2026), как и «продажу без торгов».
  # Только наши разделы: недвижимость, земля, транспорт (без запчастей, шин, ж/д), спецтехника (без запчастей), оборудование.
  # Список — адрес фильтра /catalog/<раздел>/filter/sale_method-is-<auction|sale>/apply/, по 100 лотов на странице;
  # листать страницы robots.txt запрещает (?PAGEN_1=) — где лотов 100, делим список фильтром цены
  # (start_price-from-A-to-B) на части меньше сотни. Если у раздела такого вида продажи нет, площадка молча показывает
  # «Все» (с объявлениями) — такой ответ считаем пустым. Лот — /catalog/…/<код из 20 знаков>/: вкладки с полями
  # «название — значение», история аукциона (состояние, заявки, ставки). Завершённые торги из каталога исчезают
  # (архива нет), часть страниц потом удаляется. Очные торги — итогов онлайн нет (как у МГЦН).
  GS = 'https://gostorg.by'
  GS_SALE = { 'auction' => 'Электронные торги', 'sale' => 'Очные торги' }.freeze
  # [раздел каталога, наш раздел (nil — недвижимость или право аренды по названию), подразделы-исключения]
  GS_PLAN = [['nedvizhimost', nil], ['zemlya', nil],
             ['transport/avtomobili-s-probegom', 'avto'], ['transport/avtobusy', 'gruz'], ['transport/gruzovoy-transport', 'gruz'],
             ['transport/pritsepy-polupritsepy', 'gruz'], ['transport/mototekhnika', 'gruz'], ['transport/vozdushnyy-vodnyy-transport', 'gruz'],
             ['spets-selkhoz-tekhnika', 'spec', %r{/spets-selkhoz-tekhnika/zapchasti}], ['oborudovanie', 'oborud']].freeze
  GS_FROM = { 'oborudovanie' => 500 }.freeze   # дешёвое оборудование робот всё равно отсеет порогом раздела

  # одна страница фильтра: карточки или nil (не прочитана); [] — пусто или фильтр не применился
  def gs_page(path, sale, lo = nil, hi = nil)
    pr = if lo && hi then "start_price-from-#{lo}-to-#{hi}/"
         elsif lo then "start_price-from-#{lo}/"
         elsif hi then "start_price-to-#{hi}/"
         else ''
         end
    h = get("#{GS}/catalog/#{path}/filter/sale_method-is-#{sale}/#{pr}apply/") or return nil
    cur = txt(h[/Вид продажи.{0,3000}?data-role="currentOption"[^>]*>(.*?)</m, 1])
    return [] unless cur == GS_SALE[sale]
    h.split('class="auction-card__title"').drop(1).map do |ch|
      href = ch[%r{href="(/catalog/[^"]+/([a-z0-9]{20})/)"}, 1] or next
      { 'href' => href, 'code' => href[%r{([a-z0-9]{20})/\z}, 1], 'name' => txt(ch[%r{<h6>(.*?)</h6>}m, 1]) }
    end.compact.uniq { |c| c['code'] }
  end

  # весь список раздела по виду продажи: где 100 карточек (страница полная) — делим по цене
  def gs_all(path, sale, lo = nil, hi = nil, depth = 0)
    cards = gs_page(path, sale, lo, hi) or return nil
    sleep 1
    return cards if cards.size < 100 || depth >= 7
    a = (lo || 0).to_f
    mid = hi ? Math.sqrt([a, 1].max * hi).round : [a * 4, 2000].max.round
    left = gs_all(path, sale, lo, mid, depth + 1) or return nil
    right = gs_all(path, sale, mid, hi, depth + 1) or return nil
    (left + right).uniq { |c| c['code'] }
  end

  # раздел нашего сайта: недвижимость и земля — «Право аренды», если торгуется право аренды
  def gs_sec(sec, name)
    sec || (name.to_s =~ /аренд/i ? 'arenda' : 'nedvizhimost')
  end

  # активные: nil — какой-то список не прочитан; [] — торгов в наших разделах нет
  def gs_list
    out = []
    GS_PLAN.each do |path, sec, skip|
      GS_SALE.each_key do |sale|
        cards = gs_all(path, sale, GS_FROM[path]) or return nil
        cards.reject { |c| skip && c['href'] =~ skip }.each do |c|
          out << { 'key' => "gs-#{c['code']}", 'platform' => 'gostorg.by', 'name' => c['name'], 'url' => GS + c['href'],
                   'sec' => gs_sec(sec, c['name']), 'off' => sale == 'sale' }
        end
      end
    end
    out.uniq { |c| c['key'] }
  end

  # поля вкладок лота: «Сведения о лоте» → [[название, значение]], …
  def gs_fields(html)
    html.split('<h4>').drop(1).map do |sec|
      # поля — <name class=…>, в «Описании лота» — <div class=…>
      rows = sec.scan(%r{auction-card__tab-data-name">(.*?)</(?:name|div)>(.*?)</li>}m).map { |k, v| [txt(k), txt(v)] }
      { 'h' => txt(sec[%r{\A(.*?)</h4>}m, 1]), 'rows' => rows }
    end.reject { |s| s['rows'].empty? }
  end

  # ставка аренды из описания: «Размер ежемесячной арендной платы с учетом НДС 20 % - 16,74 б.а.в.» — готовая сумма в БАВ;
  # «… арендной платы - 1 997,40 руб.» — в рублях; «Коэффициент к базовой арендной ставке – 3,0» — только текст, без расчёта
  # (решение Артёма 09.10: базовую ставку площадка не указывает, у частных арендодателей формула МГЦН может не подходить)
  def gs_rent(text, area, loc)
    t = text.to_s
    s = t[/[^.]*ежемесячной арендной платы[^.]*?[-–—:]\s*[\d\s]+(?:[.,]\d+)?\s*(?:б\.?\s*а\.?\s*в|БАВ|базов\S* арендн\S* величин|руб|BYN)[^.]*/i]
    if s
      v = num(s[/[-–—:]\s*([\d\s]+(?:[.,]\d+)?)\s*(?:б\.?\s*а\.?\s*в|БАВ|базов|руб|BYN)/i, 1])
      return { 'k' => s =~ /руб|BYN/i ? 'byn' : 'bav_total', 'v' => v, 'raw' => s.strip } if v.positive?
    end
    k = t[/Коэффициент к базовой арендной ставке\s*[-–—:]?\s*(\d+(?:[.,]\d+)?)/i, 1]
    return nil unless k
    { 'k' => 'raw', 'raw' => t[/Коэффициент к базовой арендной ставке[^.]*?\d+(?:[.,]\d+)?/i] }
  end

  def gs_detail(html)
    secs = gs_fields(html)
    f = {}   # первое значение поля («Единица» встречается дважды: у шага торгов и у задатка)
    secs.flat_map { |s| s['rows'] }.each { |k, v| f[k] ||= v unless v.empty? }
    find = ->(re) { (f.find { |k, _| k =~ re } || [])[1] }
    hist = (secs.find { |s| s['h'] =~ /История аукциона/ } || { 'rows' => [] })['rows'].to_h
    seller = (secs.find { |s| s['h'] =~ /\AПродавец/ } || { 'rows' => [] })['rows'].to_h
    org = (secs.find { |s| s['h'] =~ /\AОрганизатор/ } || { 'rows' => [] })['rows'].to_h
    loc = find.(/\AМестоположение/).to_s
    alt = find.(/\AПри местоположении вне/).to_s   # уточнённый адрес («Минская обл., Молодечненский р-н., г. Молодечно, ул. …»)
    loc = alt if alt =~ /обл|Минск/ && alt.size > loc.size
    loc = loc.sub(/\AМинск\b/, 'г. Минск')   # «Минск, Ботаническая улица» — иначе определится как Минская область
    desc = [find.(/\AХарактеристики/), find.(/\AПримечание/)].compact.join(' ').strip
    area = (a = find.(/\AПлощадь общая/)) && num(a[/[\d.,]+/])
    price = num(find.(/\AНачальная цена лота/))
    step = find.(/\AШаг торгов/).to_s
    pct = find.(/\AЕдиница/)   # первая «Единица» — у шага торгов
    fee = find.(/\AРазмер затрат\/вознаграждения/).to_s
    cond = [['Карточка №', html[/id="bx_detail_(\d+)/, 1]], ['Вид продажи', find.(/\AВид продажи/)], ['Лот', find.(/\AНомер лота в аукционе/)],
            ['Начальная цена', price.positive? ? "#{find.(/\AНачальная цена лота/)} BYN#{find.(/\AЕсть ли НДС/) == 'Да' ? ', с НДС' : ''}" : nil],
            ['Шаг торгов', step.empty? ? nil : "#{step} #{pct == '%' ? '%' : 'BYN'}"], ['Размер задатка', (d = find.(/\AРазмер задатка/)) && "#{d} BYN"],
            ['Приём заявок до', find.(/\AДата и время окончания приема заявок/)], ['Начало торгов', find.(/\AДата и время начала проведения торгов/)],
            ['Место торгов', find.(/\AАдрес проведения торгов/)], ['Затраты и вознаграждение', fee.empty? ? nil : fee],
            ['Порядок оплаты', find.(/\AПорядок и сроки оплаты/)]].reject { |_, v| v.to_s.empty? }
    about = [['Описание', desc], ['Местоположение', loc], ['Год постройки', find.(/\AГод постройки/)], ['Площадь', find.(/\AПлощадь общая/)],
             ['Инвентарный номер', find.(/\AИнвентарный номер/)], ['Форма собственности', find.(/\AФорма собственности/)],
             ['Собственник', find.(/\AСобственник имущества/)]].reject { |_, v| v.to_s.empty? }
    out = [{ 'h' => 'Условия торгов', 'rows' => cond }, { 'h' => 'Сведения о лоте', 'rows' => about }]
    out << { 'h' => 'Продавец', 'rows' => [['Продавец', seller['Краткое название организации']], ['УНП', seller['УНП']]].reject { |_, v| v.to_s.empty? } }
    out << { 'h' => 'Осмотр', 'rows' => (secs.find { |s| s['h'] =~ /осмотр/i } || { 'rows' => [] })['rows'] }
    out << { 'h' => 'Организатор торгов', 'rows' => [['Организатор', org['Краткое название организации']], ['Телефон', org['Номер телефона']]].reject { |_, v| v.to_s.empty? } }
    pics = photos('gostorg.by', html)
    # «Право заключения договора аренды» без объекта — берём полное наименование лота («… части изолированного помещения …»)
    name = find.(/\AКраткое наименование/).to_s
    full = find.(/\AНомер лота в аукционе/).to_s.sub(%r{\A\s*Лот\s*№\s*\d+\s*/\s*}, '')
    name = full if name =~ /\AПраво заключения договора аренды\.?\z/i && full.size > name.size
    { 'details' => out.reject { |s| s['rows'].empty? }, 'name' => name.empty? ? nil : name, 'art' => html[/id="bx_detail_(\d+)/, 1],
      'location' => loc.empty? ? nil : loc, 'debtor' => seller['Краткое название организации'],
      'req_to' => ts(find.(/\AДата и время окончания приема заявок/)), 'torg' => ts(find.(/\AДата и время начала проведения торгов/)),
      'price_byn' => price, 'area_num' => area, 'photo_url' => pics.first, 'photos' => pics, 'status' => hist['Состояние'],
      'off' => find.(/\AВид продажи/).to_s =~ /Очные/ ? true : nil, 'rent' => gs_rent(desc, area, loc),
      'terms' => { 'deposit' => num(find.(/\AРазмер задатка/)), 'step_pct' => pct == '%' ? num(step) : nil,
                   'step_abs' => pct == '%' ? nil : num(step), 'fee_pct' => fee[/(\d+(?:[.,]\d+)?)\s*%\s*от цены продажи/, 1]&.tr(',', '.')&.to_f,
                   'vat' => find.(/\AЕсть ли НДС/) == 'Да' ? 'Начальная цена — с НДС' : nil, 'v' => 2 }
                 .reject { |_, v| v.nil? || v == 0.0 } }
  end

  # ---------------- bankrot-torg.by и specrealization.by (один разработчик, один движок) ----------------
  # ЗАО «БелБанкротАукцион» и ООО «СпецРеализация»: имущество в банкротстве и ликвидации. Сайт на Laravel + Inertia:
  # данные страницы лежат в ней же JSON-ом (атрибут data-page). robots.txt разрешает всё.
  #   список  bankrot-torg.by/auctions — все активные одной страницей; specrealization.by/auctions?page=N — по 12,
  #           от поздних торгов к ранним, вместе с завершёнными (в списке есть раздел и срок заявок)
  #   лот     /auctions/show/<id>: props.auction — статус, вид торгов, цены, сроки, адрес, продавец, ставки
  # Прямые продажи (без торгов) не берём. Ключи: bk-<id>, sr-<id>.
  VL = { 'bankrot-torg.by' => 'https://bankrot-torg.by', 'specrealization.by' => 'https://specrealization.by' }.freeze
  VL_KEY = { 'bankrot-torg.by' => 'bk', 'specrealization.by' => 'sr' }.freeze
  # раздел площадки → наш (остальное — мебель, оргтехника, стройматериалы, дебиторка, одежда… — не берём)
  VL_SEC = { 'Недвижимость' => 'nedvizhimost', 'Легковой транспорт' => 'avto', 'Легковой автомобиль' => 'avto',
             'Грузовой транспорт' => 'gruz', 'Грузовые автомобили' => 'gruz', 'Прицепы и полуприцепы' => 'gruz', 'Прицепы, полуприцепы' => 'gruz',
             'Автобусы, микроавтобусы' => 'gruz', 'Спецтехника' => 'spec', 'Специальная с/х техника' => 'spec',
             'Оборудование' => 'oborud', 'Станки' => 'oborud', 'Станки,оборудование' => 'oborud', 'Оборудование для торговли' => 'oborud',
             'Емкости' => 'oborud' }.freeze
  # регионы bankrot-torg.by (region_id); адрес у лота часто без области
  VL_REG = { 1 => 'г. Минск', 2 => 'Минская обл.', 4 => 'Брестская обл.', 5 => 'Витебская обл.', 6 => 'Гродненская обл.' }.freeze

  def vl_props(url)
    h = get(url) or return nil
    d = h[/data-page="([^"]+)"/, 1] or return nil
    JSON.parse(decode(d))['props']
  rescue JSON::ParserError
    nil
  end

  def vl_t(s)
    s = s.to_s.strip
    return nil if s.empty?
    s =~ %r{\A\d{2}/\d{2}/\d{4}} ? ts(s.tr('/', '.')) : Time.parse(s).to_i
  rescue ArgumentError
    nil
  end

  def vl_sec(cat, title)
    s = VL_SEC[cat.to_s.strip] or return nil
    s == 'nedvizhimost' && title.to_s =~ /право (заключения договора )?аренды|право аренды/i ? 'arenda' : s
  end

  def vl_card(plat, x, sec)
    host = VL[plat]
    { 'key' => "#{VL_KEY[plat]}-#{x['id']}", 'platform' => plat, 'art' => (x['number'] || x['id']).to_s,
      'name' => x['title'].to_s.gsub(/\s+/, ' ').strip, 'url' => "#{host}/auctions/show/#{x['id']}", 'sec' => sec,
      'price' => x['start_price'].to_f, 'req_to' => vl_t(x['date_end_requests']), 'status' => x['status'],
      'thumb' => (i = (x['images'] || [x['image']]).compact.first) && (i =~ /\Ahttps?:/ ? i : "#{host}/storage/#{i}") }
  end

  # активные лоты: nil — список не прочитан
  def vl_list(plat)
    host = VL[plat]
    if plat == 'bankrot-torg.by'
      pr = vl_props("#{host}/auctions") or return nil
      return pr['list']['data'].map { |x| vl_card(plat, x, nil) }   # раздела в списке нет — он в карточке лота
    end
    out = []
    (1..40).each do |p|
      pr = vl_props("#{host}/auctions?page=#{p}")
      return nil if pr.nil? && p == 1
      items = (pr || {})['list'] || []
      break if items.empty?
      items.each { |x| (s = vl_sec(x['category'], x['title'])) && x['type'] !~ /прям/i and out << vl_card(plat, x, s) }
      break if items.all? { |x| vl_t(x['date_bargains']).to_i < Time.now.to_i - 3 * 86_400 }   # дальше — только завершённые
      sleep 1
    end
    out.uniq { |c| c['key'] }
  end

  # завершённые торги для архива (backfill.rb), от поздних к ранним. specrealization: список продолжается завершёнными;
  # bankrot-torg: в списке только идущие — завершённые по номерам страниц /auctions/show/N вниз от последнего
  # (номера идут по времени: 12.10 — № 4800, год назад — ≈ 2800). Раздел, дата и итог — со страницы лота.
  def vl_archive(plat)
    host = VL[plat]
    Enumerator.new do |y|
      if plat == 'bankrot-torg.by'
        top = (((vl_props("#{host}/auctions") || {})['list'] || {})['data'] || []).map { |x| x['id'].to_i }.max
        top&.downto(1) { |id| y << { 'key' => "bk-#{id}", 'platform' => plat, 'art' => id.to_s, 'url' => "#{host}/auctions/show/#{id}" } }
      else
        (1..400).each do |p|
          items = (vl_props("#{host}/auctions?page=#{p}") || {})['list'] || []
          break if items.empty?
          items.each { |x| (s = vl_sec(x['category'], x['title'])) && x['type'] !~ /прям/i and y << vl_card(plat, x, s) }
          sleep 1
        end
      end
    end
  end

  def vl_detail(plat, html)
    host = VL[plat]
    d = html[/data-page="([^"]+)"/, 1] or return nil
    pr = JSON.parse(decode(d))['props']
    a = pr['auction'] or return nil
    sb = pr['subjectBidding'] || {}
    sec = vl_sec(a['category_label'], a['title'])
    return { 'skip' => true } if sec.nil? || "#{a['type']} #{a['type_label']}" =~ /прям|без торгов/i
    adr = a['address'].to_s.strip.sub(/\.\z/, '').sub(/\AМинск\b/, 'г. Минск')   # «Минск» без «г.» — иначе Минская область
    loc = [adr =~ /обл|Минск/ ? nil : VL_REG[a['region_id'].to_i], adr].compact.reject(&:empty?).join(', ')
    loc = '' if loc =~ /\A[\s,]*\z/
    desc = txt(a['description'] || sb['description']).strip
    pics = (a['images'] || []).map { |i| i =~ /\Ahttps?:/ ? i : "#{host}/storage/#{i}" }
    price = a['start_price'].to_f
    min = a['min_price'].to_f
    dep = num(a['deposit_amount'])
    fee = a['organization_cost'].to_s
    seller = pr['seller'].is_a?(Hash) ? pr['seller']['name'] : a['seller'].to_s.sub(/\s*\(УНП.*\z/m, '')
    byn = ->(v) { v.to_f.positive? ? format('%.2f', v).sub(/\A\d+/) { |i| i.reverse.scan(/\d{1,3}/).join(' ').reverse }.sub('.', ',') + ' BYN' : nil }
    dtm = ->(s) { (t = vl_t(s)) && Time.at(t).strftime('%d.%m.%Y %H:%M') }
    cond = [['Номер торгов', a['full_number'] || a['number']], ['Вид торгов', [a['type_label'], a['bet_type'] == 'down' ? 'на понижение' : nil].compact.join(', ')],
            ['Начальная цена', byn.(price)], ['Минимальная цена', min.positive? && min < price ? byn.(min) : nil],
            ['Задаток', dep.positive? ? byn.(dep) : nil], ['Шаг торгов', a['step_price'] && "#{a['step_price'].to_s.sub(/\.0+\z/, '')} %"],
            ['Приём заявок до', dtm.(a['end_requests'])], ['Начало торгов', dtm.(a['start_bargains'])],
            ['Затраты и сборы', fee =~ /\A[\d.,\s]+\z/ ? byn.(num(fee)) : fee], ['Срок договора', sb['timeConcludeContact']],
            ['Срок оплаты', sb['timePayTransaction']], ['Сведения', a['info_message']]].map { |k, v| [k, v.to_s.strip] }.reject { |_, v| v.empty? }
    about = [['Описание', desc], ['Местонахождение', loc], ['Осмотр', a['contactNumber'] || sb['contactNumber']], ['Раздел', a['category_label']]]
            .map { |k, v| [k, txt(v.to_s)] }.reject { |_, v| v.empty? }
    sel = pr['seller'].is_a?(Hash) ? [['Продавец', pr['seller']['name']], ['Кто продаёт', pr['seller']['type']], ['Адрес', pr['seller']['address']]] : [['Продавец', a['seller']]]
    secs = [{ 'h' => 'Условия торгов', 'rows' => cond }, { 'h' => 'Сведения о лоте', 'rows' => about },
            { 'h' => 'Продавец', 'rows' => sel.map { |k, v| [k, v.to_s.strip] }.reject { |_, v| v.empty? } }].reject { |s| s['rows'].empty? }
    { 'details' => secs, 'name' => a['title'].to_s.gsub(/\s+/, ' ').strip, 'sec' => sec, 'location' => loc.empty? ? nil : loc,
      'debtor' => seller.to_s.strip.empty? ? nil : seller.to_s.strip, 'req_to' => vl_t(a['end_requests']), 'torg' => vl_t(a['start_bargains']),
      'price_byn' => price, 'photo_url' => pics.first, 'photos' => pics, 'status' => a['status'],
      'off' => a['type'].to_s == 'in-person' || a['type_label'].to_s =~ /очн/i ? true : nil,
      'area_num' => (x = desc[/площадь[юи]?\s*([\d\s]+[.,]?\d*)\s*(?:кв\.?\s*м|м2|м²)/i, 1] || a['title'].to_s[/площадь[юи]?\s*([\d\s]+[.,]?\d*)\s*(?:кв\.?\s*м|м2|м²)/i, 1]) && num(x),
      'terms' => { 'deposit' => dep, 'step_pct' => a['step_price'].to_f, 'min_price' => min.positive? && min < price ? min : nil,
                   'fee_abs' => fee =~ /\A[\d.,\s]+\z/ ? num(fee) : nil, 'fee_pct' => fee[/аукционный сбор\s*([\d.,]+)\s*%/i, 1]&.tr(',', '.')&.to_f,
                   'vat' => a['nds'].to_s == '1' ? 'Цена указана с НДС' : nil, 'v' => 2 }.reject { |_, v| v.nil? || v == 0.0 } }
  rescue JSON::ParserError
    nil
  end

  # ---------------- torgi.gov.by («Единая система электронных торгов») ----------------
  # Торги по Закону «Об урегулировании неплатежеспособности»: имущество в банкротстве, продавцы — управляющие и должники.
  # Сайт — приложение, данные — открытый API api.torgi.gov.by (robots.txt у API нет); на частые запросы отвечает 429 —
  # читаем по разделам, по 30 лотов, с паузой 3 с. Цены — в копейках, время — «тики» .NET (100 нс с 01.01.0001, UTC).
  # Список /api/lots?category=N&state=…: всё о лоте (название, адрес, цена, задаток %, начало торгов, описание, фото);
  # продавец и шаг — в /api/auctions/<аукцион>/lot/<лот>/public (там же ставки и победитель — итоги).
  # Срока подачи заявок у площадки нет: заявку и задаток принимают до начала торгов — его и считаем сроком.
  # Фото — на api.torgi.gov.by:8081 (с нашего компьютера 12.10 не открывался: без фото — заглушка).
  TG = 'https://torgi.gov.by'
  TG_API = 'https://api.torgi.gov.by/api'
  TG_STATES = '15,16,4,5,18,19,20,21,22,23'   # как у самой площадки: «идёт приём», «опубликован» и т. п.
  # раздел площадки → наш (мебель, бытовое, спорт, сырьё, запчасти, аренда транспорта и услуги — не берём)
  TG_SEC = { 13 => 'nedvizhimost', 14 => 'nedvizhimost', 15 => 'nedvizhimost', 16 => 'nedvizhimost', 17 => 'nedvizhimost',
             18 => 'nedvizhimost', 19 => 'nedvizhimost', 156 => 'nedvizhimost', 162 => 'nedvizhimost', 168 => 'arenda',
             22 => 'avto', 26 => 'avto', 20 => 'gruz', 23 => 'gruz', 24 => 'gruz', 25 => 'gruz', 139 => 'gruz',
             154 => 'spec', 141 => 'spec', 142 => 'spec', 143 => 'spec', 144 => 'spec', 145 => 'spec', 146 => 'spec', 147 => 'spec',
             148 => 'spec', 149 => 'spec', 150 => 'spec', 151 => 'spec', 152 => 'spec',
             34 => 'oborud', 35 => 'oborud', 37 => 'oborud', 38 => 'oborud' }.freeze

  # номер региона площадки → область (сверено по адресам 12.10): адрес часто без области («д. Барсеево»)
  TG_REG = { 6 => 'г. Минск', 7 => 'Брестская обл.', 8 => 'Витебская обл.', 9 => 'Гомельская обл.', 10 => 'Гродненская обл.',
             11 => 'Минская обл.', 12 => 'Могилевская обл.' }.freeze

  def tg_t(ticks)
    t = ticks.to_i
    t.positive? ? (t - 621_355_968_000_000_000) / 10_000_000 : nil
  end

  def tg_json(path)
    out = get(TG_API + path, min: 2) or return nil
    j = JSON.parse(out)
    j['status'].to_i == 200 ? j['result'] : nil
  rescue JSON::ParserError
    nil
  end

  def tg_url(l)
    slug = l['name'].to_s.downcase.gsub(/[а-яё]/) { |c| c == 'ё' ? 'e' : (LAT[c] || '') }.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')[0, 120]
    "#{TG}/lot/#{l['id']}/#{l['numAuction']}/#{slug}"
  end

  # карточка и подробности — сразу из списка (d); продавца и шаг добавит tg_detail
  def tg_card(l, sec)
    price = l['currentInitialPrice'].to_i.positive? ? l['currentInitialPrice'].to_i / 100.0 : l['initialPrice'].to_i / 100.0
    start = tg_t(l['auctionStart'])
    desc = l['description'].to_s.gsub(/\r/, '').strip
    img = (l['images'] || []).sort_by { |i| [i['main'] ? 0 : 1, i['no'].to_i] }
                              .map { |i| (i['thumbnails'] || []).max_by { |t| t['width'].to_i } }.compact.map { |t| "https://api.torgi.gov.by:8081/#{t['uid']}" }
    dep = l['depositAuction'].to_f
    cond = [['Лот №', l['id'].to_s], ['Аукцион №', l['numAuction'].to_s], ['Начальная цена', format('%.2f BYN', price).sub('.', ',') + (l['nds'].to_i == 1 ? ' (с НДС)' : '')],
            ['Задаток', dep.positive? ? "#{dep.to_s.sub(/\.0\z/, '')}% от начальной цены" : nil],
            ['Начало торгов', start && Time.at(start).strftime('%d.%m.%Y %H:%M')],
            ['Приём заявок', 'до начала торгов: заявка и задаток — через площадку']].reject { |_, v| v.to_s.empty? }
    d = { 'details' => [{ 'h' => 'Условия торгов', 'rows' => cond },
                        { 'h' => 'Сведения о лоте', 'rows' => [['Описание', desc], ['Местонахождение', l['location'].to_s]].reject { |_, v| v.empty? } }],
          'name' => l['name'].to_s.strip, 'req_to' => start, 'torg' => start, 'price_byn' => price,
          'location' => (loc = l['location'].to_s.strip) =~ /обл|Минск/ || !TG_REG[l['region'].to_i] ? loc : [TG_REG[l['region'].to_i], loc].reject(&:empty?).join(', '),
          'area_num' => (a = desc[/площадью\s*([\d\s]+[.,]?\d*)\s*(?:кв\.?\s*м|м²|м2)/i, 1]) && num(a),
          'photo_url' => tg_ph_ok? ? img.first : nil, 'photos' => [],   # галерею не храним: :8081 у посетителей часто не открывается (12.10)
          'terms' => { 'deposit' => dep.positive? ? (price * dep / 100).round(2) : nil, 'v' => 3 }.merge(tg_fee(desc))
                       .merge(vat_of(desc, l['nds'].to_i == 1)).reject { |_, v| v.nil? } }
    { 'key' => "tg-#{l['id']}", 'platform' => 'torgi.gov.by', 'art' => l['id'].to_s, 'auc' => l['numAuction'].to_s,
      'name' => d['name'], 'url' => tg_url(l), 'sec' => sec, 'price' => price, 'req_to' => start, 'd' => d }
  end

  # сборы — из описания лота: «возмещает стоимость затрат … согласно прейскуранту» — плата оператору по шкале
  # прейскуранта torgi.gov.by (от цены продажи: 5% до 50 000 руб., 4% до 250 000, 3% до 500 000, 2% до 1 млн, 1% до 10 млн,
  # дальше 0,2% — шкала в калькуляторе сайта); «возмещает затраты … в сумме 370 рублей» — сумма. Не сказано — победитель не платит
  def tg_fee(desc)
    return { 'fee_scale' => 'torgi' } if desc =~ /(?:возмещ|возмест|оплат|вознагражд)[^.]{0,140}прейскурант/i
    s = desc[/(?:возмещ|возмест)[а-яё]*[^.]{0,100}?затрат[^.]{0,100}?(?:в сумме|в размере|торгов|аукциона)\s*(\d[\d\s]*(?:[.,]\d+)?)\s*(?:руб|бел)/i, 1]
    s ? { 'fee_abs' => num(s) } : {}
  end

  # фото на :8081 открываются не всегда (12.10 — не открывались): проверяем раз за обход, иначе каждое фото ждало бы 40 с
  def tg_ph_ok?
    return @tg_ph unless @tg_ph.nil?
    @tg_ph = system('curl', '-s', '-o', File::NULL, '-m', '8', 'https://api.torgi.gov.by:8081/', out: File::NULL, err: File::NULL)
  end

  # активные лоты наших разделов: nil — какой-то раздел не прочитан
  def tg_list
    out = []
    TG_SEC.each do |cat, sec|
      (0..50).each do |p|
        r = tg_json("/lots?page=#{p}&pagesize=30&sort=start&state=#{TG_STATES}&category=#{cat}") or return nil
        lots = r['lots'] || []
        lots.each { |l| out << tg_card(l, sec) unless l['deleted'] || l['ads'] }
        sleep 3
        break if lots.size < 30 || out.size > 5000
      end
    end
    out.uniq { |c| c['key'] }
  end

  # завершённые торги (backfill.rb): «торги прошли», «продан», «не продан», «продан на аукционе» (state 6, 7, 9, 17);
  # список — от поздних торгов к ранним
  TG_DONE = '6,7,9,17'
  def tg_done(since)
    Enumerator.new do |y|
      TG_SEC.each do |cat, sec|
        (0..300).each do |p|
          r = tg_json("/lots?page=#{p}&pagesize=30&state=#{TG_DONE}&category=#{cat}") or break
          lots = r['lots'] || []
          lots.each { |l| y << tg_card(l, sec) unless l['deleted'] || l['ads'] || tg_t(l['auctionStart']).to_i < since }
          sleep 3
          break if lots.size < 30 || lots.map { |l| tg_t(l['auctionStart']).to_i }.max < since
        end
      end
    end
  end

  # продавец, шаг торгов, сроки договора и оплаты — со страницы аукциона (один запрос на новый лот;
  # архив передаёт её готовой — по ней же итог)
  def tg_detail(c, a = nil)
    d = c['d'] || {}
    unless a
      a = tg_json("/auctions/#{c['auc']}/lot/#{c['art']}/public") or return d
      sleep 2
    end
    seller = (a['organizer'] || {})['fullName'].to_s.strip
    rows = [['Шаг торгов', a['step'].to_i.positive? ? "#{a['step']} %" : nil], ['Срок заключения договора', a['contractTimeout'].to_i.positive? ? "#{a['contractTimeout']} дней" : nil],
            ['Срок оплаты', a['paymentTimeout'].to_i.positive? ? "#{a['paymentTimeout']} дней" : nil],
            ['Вид торгов', a['auctionMethod'].to_s =~ /dutch|down/i ? 'на понижение' : nil]].reject { |_, v| v.nil? }
    d = d.merge('debtor' => seller.empty? ? nil : seller)
    d['details'] = d['details'].map { |s| s['h'] == 'Условия торгов' ? s.merge('rows' => s['rows'] + rows) : s }
    d['details'] << { 'h' => 'Продавец', 'rows' => [['Продавец', seller]] } unless seller.empty?
    d['terms'] = d['terms'].merge('step_pct' => a['step'].to_f, 'pay_term' => a['paymentTimeout'].to_i.positive? ? "#{a['paymentTimeout']} дней" : nil)
                           .reject { |_, v| v.nil? || v == 0.0 }
    d
  end

  # ---------------- etpvit.by (ЭТП «Витебского областного центра маркетинга») ----------------
  # Тот же движок, что у e-auction.by: карточки списка, поля лота и служебный запрос итогов (Res.ea_info с хостом etpvit).
  # robots.txt разрешает всё. Список раздела — ?limit=100&PAGEN_1=N; в нём только идущие торги. «Готовятся к продаже»
  # (ещё не выставлены) и дебиторку не берём. В карточке — вид имущества: «Банкротство», «Государственные» и др.
  EV = 'https://etpvit.by'
  EV_PLAN = [['/nedvizhimost/', 'nedvizhimost'], ['/zemelnye_uchastki/', 'nedvizhimost'], ['/transport/', nil],
             ['/stanki_i_oborudovanie/', 'oborud'], ['/arenda_nedvizhimosti/', 'arenda'], ['/arenda_zemelnykh_uchastkov/', 'arenda']].freeze

  # транспорт: по подразделу ссылки; «другое» — по названию
  def ev_sec(href, name)
    sub = href.to_s.split('/').reject(&:empty?)[1].to_s
    return 'avto' if sub =~ /legkov/
    return 'spec' if sub =~ /spets|selkhoz/
    return 'gruz' if sub =~ /gruz|avtobus|pricep/
    a24_sec(name, 'auto')
  end

  # nil — какой-то раздел не прочитан
  def ev_cards(html, sec)
    html.split('class="product-item column').drop(1).map do |ch|
      ch = ch[0, 6000]
      href = ch[/href="(\/[^"]+)"/, 1]
      art = txt(ch[/class="product_art"[^>]*>(.*?)<\/div>/m, 1])
      next nil if href.nil? || art.empty?
      name = txt(ch[/class="text-header">(.*?)<\/div>/m, 1])
      { 'key' => "ev-#{art}", 'platform' => 'etpvit.by', 'art' => art, 'name' => name, 'url' => EV + href,
        'sec' => sec || ev_sec(href, name), 'price' => ch[/data-price="([0-9.]+)"/, 1].to_f,
        'req_to' => ch[/data-endrequest="(\d+)"/, 1].to_i, 'eid' => ch[/product-id="(\d+)"/, 1],
        'kind' => txt(ch[/class="lot-type[^"]*"[^>]*>(.*?)<\/span>/m, 1]),
        'thumb' => (u = ch[/<img src="(\/upload\/[^"]+)"/, 1]) && EV + u }
    end.compact
  end

  # done — вкладка «Завершённые» (?type=f, как у e-auction) с торгами не раньше done (backfill.rb)
  def ev_list(done = nil)
    out = []
    EV_PLAN.each do |path, sec|
      (1..(done ? 30 : 10)).each do |p|
        html = get("#{EV}#{path}?#{done ? 'type=f&' : ''}limit=100" + (p > 1 ? "&PAGEN_1=#{p}" : '')) or (done ? break : (return nil))
        cards = ev_cards(html, sec)
        fresh = cards.reject { |c| out.any? { |o| o['key'] == c['key'] } }
        out.concat(done ? fresh.select { |c| c['req_to'] >= done } : fresh)
        sleep 1
        break if cards.size < 100 || fresh.empty? || (done && fresh.map { |c| c['req_to'] }.max.to_i < done)
      end
    end
    out
  end

  def ev_detail(html)
    d = ea_detail(html)
    rows = d['details'].flat_map { |s| s['rows'] }
    d['photos'] = (d['photos'] || []).map { |u| u.sub(EA, EV) }
    d['photo_url'] = d['photo_url'] && d['photo_url'].sub(EA, EV)
    seller = (rows.find { |k, _| k == 'Наименование' } || [])[1]   # первое «Наименование» — продавец (должник)
    place = rows_find(d['details'], /Местоположение|Местонахождение|Адрес (объекта|имущества)/)
    place ||= (rows.find { |k, _| k == 'Адрес' } || [])[1].to_s.sub(/\A\d{6},\s*/, '')   # нет адреса объекта — адрес продавца
    min = num(rows_find(d['details'], /Минимальная цена/).to_s[/[\d\s.]+/])
    # условия — со страницы: «Шаг торгов фиксирован: 2 247.97 BYN … или 5% от начальной цены», «Сумма затрат на обслуживание
    # ЭТП: … или 10% от ставки победителя», затраты на организацию — «Не указано» (объявят после приёма заявок) или сумма
    tx = txt(html)
    t = { 'min_price' => min.positive? ? min : nil, 'v' => 3 }
    if (m = tx.match(/Шаг торгов фиксирован:\s*([\d\s.]+?)\s*BYN.{0,60}?или\s*([\d.,]+)\s*%\s*от начальной/))
      t['step_abs'] = num(m[1]); t['step_pct'] = num(m[2])
    end
    t['fee_pct'] = num($1) if tx =~ /затрат на обслуживание ЭТП:.{0,80}?или\s*([\d.,]+)\s*%\s*от ставки победителя/
    org = tx[/Сумма затрат на организацию и проведение торгов:?\s*(.{0,40})/, 1].to_s
    org =~ /\A[\d\s.,]+BYN/ ? t['fee_abs'] = num(org[/[\d\s.,]+/]) : t['fee_later'] = true
    # дата торгов — со страницы: служебный запрос площадки (Res.ea_info) у etpvit отдаёт её на сутки раньше (14.10, 66 лотов)
    torg = ts_words(tx[/Время начала торгов:\s*([^:]{8,30}:\d{2})/, 1])
    d['torg'] = torg if torg
    d.merge('location' => place.to_s.empty? ? nil : place, 'debtor' => seller,
            'terms' => (d['terms'] || {}).merge(t).merge(vat_of(tx)).reject { |_, v| v.nil? || v == 0.0 })
  end

  # ---------------- expert-torgi.by и realtorgi.by (один шаблон JoomShopping, как у minskestate.by) ----------------
  # expert-torgi.by — филиал «Эксперт-Услуга» ОАО «Гомельоблреклама»; realtorgi.by — ООО «Реалконсалтинг» (его раздел очных
  # торгов /ochnye-torgi — статьи-новости, последние — 2024 г., не берём). robots.txt закрывает только служебные папки. Список /auctions?start=N — по 9 карточек
  # (blockProductItemLot: ссылка, название, дата аукциона, адрес, статус, цена), вместе с завершёнными. Лот: строки
  # «Ключ: значение» (productParamItem: сроки, цены, задаток, адрес, продавец), вкладки — как у minskestate (me_detail).
  # Ключи: ex-<адрес лота>, rt-<адрес лота>.
  JM = { 'expert-torgi.by' => ['https://www.expert-torgi.by', 'ex', %w[/auctions]],
         'realtorgi.by' => ['https://realtorgi.by', 'rt', %w[/auctions]] }.freeze
  # раздел площадки (из адреса лота) → наш; запчасти, дебиторка, «другое/иное имущество» — не берём
  JM_SEC = { 'nedvizhimost' => 'nedvizhimost', 'zhilishchnyj-fond' => 'nedvizhimost', 'arenda' => 'arenda', 'oborudovanie' => 'oborud',
             'transport' => 'auto', 'transport-i-spetstekhnika' => 'auto' }.freeze

  def jm_sec(href, name)
    cat = href[%r{\A/auctions/([a-z-]+)/}, 1]
    s = cat ? JM_SEC[cat] : a24_sec(name)   # очные торги realtorgi — без раздела в адресе
    return nil unless s
    return 'spec' if s == 'auto' && name.to_s =~ /трактор|погрузчик|экскаватор|кран|комбайн|бульдозер|грейдер|каток/i
    s == 'auto' ? a24_sec(name, 'auto') : s
  end

  # nil — список не прочитан
  def jm_list(plat)
    host, pre, paths = JM[plat]
    out = []
    paths.each do |path|
      first = get("#{host}#{path}") or return nil
      last = first.scan(/start=(\d+)/).flatten.map(&:to_i).max.to_i
      (0..last / 9).each do |i|
        html = i.zero? ? first : (get("#{host}#{path}?start=#{i * 9}") or break)
        html.split(/blockProductItem(?:Lot)?[ "]/).drop(1).each do |ch|   # у realtorgi карточка — blockProductItem
          ch = ch[0, 5000]
          href = ch[%r{href="(#{path}/[^"]+)"}, 1] or next
          name = decode(ch[/moduleProductName">\s*<a [^>]*title="([^"]+)"/, 1].to_s).strip
          sec = jm_sec(href, name) or next
          out << { 'key' => "#{pre}-#{href.split('/').last}", 'platform' => plat, 'name' => name, 'url' => host + href, 'sec' => sec,
                   'status' => txt(ch[%r{listLotStatus">(.*?)</div>}m, 1]), 'price' => num(txt(ch[%r{listAuctionActualPrice">(.*?)</div>}m, 1])),
                   'off' => path =~ /ochn/ ? true : nil, 'thumb' => ch[/<img[^>]+src="(https?:[^"]+)"/, 1] }
        end
        sleep 1 unless i.zero?
      end
    end
    out.uniq { |c| c['key'] }
  end

  def jm_detail(plat, html)
    host = JM[plat][0]
    d = me_detail(html)
    pr = html.scan(%r{productParamItem[^"]*">(.*?)</div>}m).map { |(x)| txt(x).split(/:\s*/, 2) }.select { |x| x.size == 2 }.to_h
    price = num(pr['Начальная цена'].to_s[/[\d\s.,]+/])
    dep = num(pr['Размер задатка'].to_s[/[\d\s.,]+/])
    cond = [['№ лота', pr['№ лота']], ['Тип торгов', pr['Тип торгов']], ['Начальная цена', pr['Начальная цена']], ['Размер задатка', pr['Размер задатка']],
            ['Приём заявок с', pr['Начало приема заявок']], ['Приём заявок до', pr['Окончание приема заявок']],
            ['Начало торгов', pr['Начало торгов']], ['Шаг торгов', txt(html[/Шаг торгов:\s*(.*?)<\/div>/m, 1])]].reject { |_, v| v.to_s.strip.empty? }
    secs = d['details'].map { |s| s['h'] == 'Условия торгов' ? s.merge('rows' => cond) : s }.reject { |s| s['rows'].empty? }
    pics = html.scan(%r{(https?://[^"'\s]+/img_products/[^"'\s]*/full_[^"'\s]+\.(?:jpe?g|png|webp))}i).flatten.uniq
    pics = html.scan(%r{(/components/com_jshopping/files/img_products/[^"'\s]*/full_[^"'\s]+\.(?:jpe?g|png|webp))}i).flatten.uniq.map { |u| host + u } if pics.empty?
    torg = ts(pr['Начало торгов']) || ts(pr['Дата аукциона'].to_s + ' 12:00')
    d.merge('details' => secs, 'art' => pr['№ лота'], 'location' => pr['Адрес'].to_s.strip.empty? ? d['location'] : pr['Адрес'].strip,
            'debtor' => pr['Продавец'] || d['debtor'], 'req_to' => ts(pr['Окончание приема заявок']) || torg, 'torg' => torg,
            'price_byn' => price.positive? ? price : d['price_byn'], 'photo_url' => pics.first, 'photos' => pics,
            'status' => txt(html[/Статус:\s*(.*?)<\/div>/m, 1]),
            'terms' => { 'deposit' => dep.positive? ? dep : nil, 'step_abs' => num(txt(html[/Шаг торгов:\s*(.*?)<\/div>/m, 1]).to_s[/[\d\s.,]+/]), 'v' => 3 }
                       .merge(jm_fee(txt(html))).merge(vat_of(pr['Начальная цена'].to_s)).reject { |_, v| v.nil? || v == 0.0 })
  end

  # сборы — из «Обязанностей победителя» на странице лота (13.10):
  # expert-torgi — «вознаграждение … в размере 7% от начальной цены лота»; realtorgi — «вознаграждение в размере 5% от цены
  # продажи лота», «Сумма затрат: до 300 рублей (точная сумма будет опубликована до дня аукциона)», единственный участник +5%
  def jm_fee(tx)
    t = {}
    if (m = tx.match(/вознагражд[а-яё]*\)?[^.;]{0,90}?в размере\s*([\d.,]+)\s*%\s*от\s*(начальной цены|цены продажи)/i))
      t['fee_pct'] = num(m[1]); t['fee_base'] = 'start' if m[2] =~ /начальной/i
    end
    if (m = tx.match(/Сумма затрат:\s*(до\s*)?([\d\s.,]+?)\s*руб/i))
      t['fee_abs'] = num(m[2]); t['fee_upto'] = true if m[1]
    end
    t['single_pct'] = num($1) if tx =~ /по начальной цене,? увеличенной на (\d+) процент/i
    t
  end

  # ---------------- iintorgi.by («ИИН Торги», ООО «Индустрия Инноваций-Торги») ----------------
  # Сайт — приложение (Nuxt), данные — открытый JSON /admin/api/admin/lot?status=…&page_size=100 (robots.txt нет). Статусы:
  # «Прием заявок», «Предстоящие», «Проводятся торги» — берём; «Изучение спроса» (цена 0, торги не назначены — как
  # «объявления» gostorg) и завершённые — нет. В строке списка — всё о лоте и аукционе (сроки — unix-время, продавец,
  # управляющий в банкротстве, фото /admin/storage/…). Лот — /admin/api/admin/lot/<id> (там же статус для итогов).
  II = 'https://iintorgi.by'
  II_ST = ['Прием заявок', 'Предстоящие', 'Проводятся торги'].freeze

  def ii_sec(cat, name)
    n = name.to_s
    case cat.to_s
    when /Недвижим/ then n =~ /\A\s*право\b|право (заключения договора )?аренды/i ? 'arenda' : 'nedvizhimost'   # «…на участке в аренду» — продажа
    when /Транспорт/ then n =~ /запчаст|шин[аы]|диск/i ? nil : (n =~ /трактор|погрузчик|экскаватор|кран|комбайн|бульдозер|грейдер|каток/i ? 'spec' : a24_sec(n, 'auto'))
    when /Оборудован/ then 'oborud'
    end
  end

  def ii_card(x)
    a = x['auction'] || {}
    name = x['name'].to_s.strip
    sec = ii_sec((x['category'] || {})['name'], name) or return nil
    t = ->(v) { v.to_i.positive? ? v.to_i : nil }
    req = t.(a['ends_at']); torg = t.(a['start_selling']) || t.(x['descending_step'])
    price = x['price_start'].to_f
    min = x['price_min'].to_f
    pics = (x['gallery'] || []).map { |g| g['path'] }.compact.map { |p| II + p }
    h = ->(s) { txt(s.to_s) }
    cond = [['Лот №', x['lot_number']], ['Аукцион №', a['auction_number']], ['Вид торгов', a['auction_type'] == 'descending' ? 'на понижение' : nil],
            ['Начальная цена', format('%.2f BYN', price).sub('.', ',')], ['Минимальная цена', min.positive? && min < price ? format('%.2f BYN', min).sub('.', ',') : nil],
            ['Задаток', x['deposit'].to_f.positive? ? format('%.2f BYN', x['deposit'].to_f).sub('.', ',') : nil],
            ['Приём заявок до', req && Time.at(req).strftime('%d.%m.%Y %H:%M')], ['Начало торгов', torg && Time.at(torg).strftime('%d.%m.%Y %H:%M')],
            ['Порядок торгов', h.(x['bidding_information'])], ['Затраты', h.(x['expenses_information'])],
            ['Срок договора, дней', x['sign_agreements_time']], ['Срок оплаты, дней', x['pay_time']]].map { |k, v| [k, v.to_s.strip] }.reject { |_, v| v.empty? }
    about = [['Описание', h.(x['info'])], ['Местонахождение', x['address'].to_s.strip], ['Осмотр', h.(a['how_to_view_the_property'])]].reject { |_, v| v.empty? }
    seller = [['Продавец', h.(a['seller_custom'])], ['Управляющий', h.(a['anticrisis_manager'])], ['Организатор', h.(a['organizer_requisites'])]].reject { |_, v| v.empty? }
    debtor = h.(a['anticrisis_manager'])[/\A(.+?)\s+в лице/, 1] || h.(a['seller_custom'])[/Собственник имущества:\s*(.+?)(?:\s+в лице|,|\z)/, 1]
    d = { 'details' => [{ 'h' => 'Условия торгов', 'rows' => cond }, { 'h' => 'Сведения о лоте', 'rows' => about }, { 'h' => 'Продавец', 'rows' => seller }].reject { |s| s['rows'].empty? },
          'name' => name, 'location' => x['address'].to_s.strip, 'debtor' => debtor, 'req_to' => req, 'torg' => torg, 'price_byn' => price,
          'area_num' => (m = name[/([\d\s]+[.,]?\d*)\s*кв\.?\s*м/, 1]) && num(m), 'photo_url' => pics.first, 'photos' => pics,
          'terms' => { 'deposit' => x['deposit'].to_f, 'step_pct' => x['price_step'].to_f, 'min_price' => min.positive? && min < price ? min : nil,
                       'vat' => x['nds'].to_i == 1 ? 'Цена указана с НДС' : nil, 'v' => 3 }.merge(ii_fee(h.(x['additional_info'])))
                     .reject { |_, v| v.nil? || v == 0.0 } }
    { 'key' => "ii-#{x['id']}", 'platform' => 'iintorgi.by', 'art' => x['lot_number'].to_s, 'name' => name, 'url' => "#{II}/auctions/#{x['id']}",
      'sec' => sec, 'price' => price, 'req_to' => req, 'status' => x['status'], 'd' => d }
  end

  # nil — список не прочитан
  # завершённые торги (backfill.rb): [карточка, лот из API — по нему итог]
  II_DONE = ['Торги состоялись', 'Покупка состоялась', 'Торги не состоялись', 'Отмененные торги'].freeze
  # сборы — из «Обязанностей победителя» (additional_info, 13.10): «возместить затраты на организацию электронного аукциона
  # в размере 22,00 бел. руб.», «вознаграждение … в размере 1,5 % от конечной цены продажи лота, но не менее 200,00 бел. руб.»
  def ii_fee(tx)
    t = {}
    t['fee_abs'] = num($1) if tx =~ /возместить затраты на организацию[^;]{0,80}?в размере\s*(\d[\d\s]*(?:[.,]\d+)?)\s*бел/i
    if (m = tx.match(/вознагражд[а-яё]*[^;]{0,80}?в размере\s*([\d.,]+)\s*%\s*от[^;]{0,40}?цены(?:[^;]{0,40}?не менее\s*(\d[\d\s]*(?:[.,]\d+)?)\s*бел)?/i))
      t['fee_pct'] = num(m[1]); t['fee_min'] = num(m[2]) if m[2]
    end
    t
  end

  def ii_done(since)
    Enumerator.new do |y|
      II_DONE.each do |st|
        (1..40).each do |p|
          q = URI.encode_www_form('auction_type' => 'no', 'status' => st, 'category' => 'Все', 'price_order' => 'no', 'city' => 'Город', 'page_size' => 100, 'page' => p)
          body = get("#{II}/admin/api/admin/lot?#{q}", min: 2) or break
          d = (JSON.parse(body)['data'] rescue nil) or break
          (d['data'] || []).each { |x| (c = ii_card(x)) && (c['d']['torg'] || c['req_to']).to_i >= since and y << [c, x] }
          sleep 1
          break if p >= d['last_page'].to_i
        end
      end
    end
  end

  def ii_list
    out = []
    II_ST.each do |st|
      (1..20).each do |p|
        q = URI.encode_www_form('auction_type' => 'no', 'status' => st, 'category' => 'Все', 'price_order' => 'no', 'city' => 'Город', 'page_size' => 100, 'page' => p)
        body = get("#{II}/admin/api/admin/lot?#{q}", min: 2) or return nil
        d = (JSON.parse(body)['data'] rescue nil) or return nil
        (d['data'] || []).each { |x| (c = ii_card(x)) && out << c }
        sleep 1
        break if p >= d['last_page'].to_i
      end
    end
    out.uniq { |c| c['key'] }
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
