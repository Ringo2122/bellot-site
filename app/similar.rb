# encoding: utf-8
#
# «Сколько за такие отдают на самом деле» — для каждого лота на сайте (build.rb):
#   c     похожие завершённые торги: сводка (завершилось, продано, медианы) и до 6 лотов;
#   h     история объекта: прошлые (и новые) торги того же объекта на любой площадке;
#   prev  лоты архива — прошлые торги того же объекта: по ним кабинет сообщает «выставлен снова».
# Кого сравниваем (правила Артёма, 25.09.2026):
#   недвижимость — тот же населённый пункт и та же категория (квартиры с квартирами, склады со складами);
#   легковые, грузовые и автобусы, спецтехника — та же марка и модель, год выпуска ±2, регион не важен;
#   разделы между собой не смешиваем, оборудование не сравниваем. Подходящих нет — блока нет.
# Тот же объект: VIN, инвентарный номер ЕГРНИ, кадастровый номер (только у земельных участков: у зданий
# это номер участка под ними, на одном участке бывает несколько лотов); недвижимость — ещё то же название
# в том же населённом пункте. Пул — итоги из памяти робота и таблица sales (итоги старше архива).
require_relative 'objects'

module Similar
  module_function

  FINAL = %w[sold single failed cancelled].freeze
  SOLD = %w[sold single].freeze
  VEH = %w[avto gruz spec].freeze
  YEARS = 2

  def med(a)
    return nil if a.empty?
    s = a.sort
    m = s.size / 2
    s.size.odd? ? s[m] : (s[m - 1] + s[m]) / 2.0
  end

  def info(l, rows)
    o = { 'ids' => Obj.ids(l['name'], rows) }
    if l['section'] == 'nedvizhimost'
      o['kind'] = Obj.realty_kind(l['name'])
      o['city'] = Obj.city(l['location'], l['name'])
      o['ids'].reject! { |x| x.start_with?('kad:') } unless o['kind'] == 'Земельные участки'
      nm = Obj.low(l['name']).gsub(/[^a-zа-я0-9]/, '')
      o['nm'] = "#{o['city']}|#{nm}" if o['city'] && nm.size >= 20
    elsif VEH.include?(l['section'])
      o['veh'] = Obj.vehicle(l, rows)
    end
    o
  end

  def brand_ru(b)
    b.split(/([ -])/).map { |w| w.size > 3 ? w.capitalize : w }.join
  end

  def model_ru(m)
    m =~ /\A[A-Z]{4,}\z/ ? m.capitalize : m
  end

  # lots — память после правок админки; shown — key → id лотов, которые есть на сайте;
  # sales — строки таблицы sales; rows — ->(key) { строки подробностей }
  def run(lots, shown, sales, rows)
    by_key = {}
    inf = {}
    lots.each do |l|
      by_key[l['key']] = l
      inf[l['key']] = info(l, Obj.rows_of(rows.(l['key'])))
    end
    # итоги старше архива — только из таблицы sales
    extra = sales.reject { |x| by_key[x['key']] }.group_by { |x| x['key'] }
    extra.each { |k, xs| inf[k] = info(xs.first, []) }

    # ── один объект: объединяем ключи по идентификаторам ──
    par = {}
    find = ->(k) { par[k] ||= k; par[k] == k ? k : (par[k] = find.(par[k])) }
    uni = ->(a, b) { ra = find.(a); rb = find.(b); par[ra] = rb unless ra == rb }
    first = {}
    inf.each do |k, o|
      (o['ids'] + [o['nm'] && "nm:#{o['nm']}"].compact).each { |id| first[id] ? uni.(k, first[id]) : (first[id] = k) }
    end
    groups = inf.keys.group_by { |k| find.(k) }

    # ── торги: каждое завершение — отдельная запись ──
    ent = ->(k, l, r, st) do
      { 'k' => k, 'id' => shown[k], 'n' => l['name'].to_s[0, 140], 'p' => l['platform'], 'u' => l['url'],
        'd' => (r && r['at'] || l['closed'] || l['req_to']).to_i, 's' => (r && r['start'].to_f.positive? ? r['start'] : l['price']).to_f.round,
        'st' => st, 'pr' => r && SOLD.include?(st) && r['price'].to_f.positive? ? r['price'].to_f.round : nil,
        'us' => r && r['users'].to_i.positive? ? r['users'].to_i : nil, 'a' => (l['area_num'].to_f.positive? ? l['area_num'].to_f : nil),
        'sec' => l['section'], 'loc' => l['location'] }
    end
    auctions = Hash.new { |h, k| h[k] = [] }   # key → [запись…], текущие торги лота — с меткой cur
    lots.each do |l|
      k = l['key']
      done = ([l['result']] + (l['results'] || [])).compact.select { |r| FINAL.include?(r['st']) }
      done.each { |r| auctions[k] << ent.(k, l, r, r['st']).merge('cur' => r.equal?(l['result'])) }
      if l['status'] == 'active'
        auctions[k] << ent.(k, l, nil, 'active').merge('d' => l['req_to'].to_i, 'cur' => true)
      elsif !(l['result'] && FINAL.include?(l['result']['st']))
        auctions[k] << ent.(k, l, l['result'], l['why'] == 'removed' ? 'removed' : 'pending').merge('cur' => true)
      end
    end
    extra.each { |k, xs| xs.each { |x| auctions[k] << ent.(k, x.merge('closed' => x['at']), x, x['st']) } }

    # ── пул для сравнения: только завершённые торги ──
    idx = Hash.new { |h, k| h[k] = [] }
    auctions.each do |k, as|
      o = inf[k] or next
      key = if o['veh'] then "v|#{as.first['sec']}|#{o['veh']['b']}|#{o['veh']['m']}"
            elsif o['kind'] && o['city'] then "r|#{o['city']}|#{o['kind']}"
            end
      next unless key
      as.each { |a| idx[key] << [k, a] if FINAL.include?(a['st']) }
    end

    out = {}
    shown.each_key do |k|
      l = by_key[k] or next
      o = inf[k]
      g = find.(k)
      res = {}
      # история: все торги объекта, кроме текущих торгов этого лота
      mates = groups[g] || [k]
      h = mates.flat_map { |m| auctions[m].reject { |a| m == k && a['cur'] } }.sort_by { |a| -a['d'] }.first(12)
      res['h'] = h.map { |a| a.reject { |x, _| %w[k cur sec loc a].include?(x) } } unless h.empty?
      prev = mates.reject { |m| m == k }.select { |m| by_key[m] && by_key[m]['status'] == 'archive' && shown[m] }.map { |m| shown[m] }
      res['prev'] = prev unless prev.empty?
      # похожие: другие объекты по правилам раздела
      key, label = if o['veh']
                     v = o['veh']
                     ["v|#{l['section']}|#{v['b']}|#{v['m']}", "#{brand_ru(v['b'])} #{model_ru(v['m'])}, #{v['y'] - YEARS}–#{v['y'] + YEARS} г. в."]
                   elsif o['kind'] && o['city']
                     ["r|#{o['city']}|#{o['kind']}", "#{o['kind']}, #{o['city'].start_with?('г|') ? 'г. ' : ''}#{Obj.town_name(o['city'])}"]
                   end
      if key
        cand = idx[key].reject { |m, _| find.(m) == g }
        cand = cand.select { |m, _| (inf[m]['veh']['y'] - o['veh']['y']).abs <= YEARS } if o['veh']
        unless cand.empty?
          xs = cand.map { |m, a| a.merge('y' => o['veh'] && inf[m]['veh']['y']) }
          sold = xs.select { |a| a['pr'] }
          pm = sold.select { |a| a['s'].positive? }.map { |a| (a['pr'].to_f / a['s'] - 1) * 100 }
          sqm = sold.select { |a| a['a'] }.map { |a| a['pr'] / a['a'] }
          # в списке одинаковые строки (тот же лот в двух разделах площадки) — один раз
          items = (sold.sort_by { |a| -a['d'] } + (xs - sold).sort_by { |a| -a['d'] }).uniq { |a| [a['p'], a['d'], a['s'], a['pr'], a['st']] }.first(6)
          res['c'] = { 'by' => label, 'n' => xs.size, 'sold' => sold.size, 'pm' => pm.empty? ? nil : med(pm).round,
                       'pr' => sold.empty? ? nil : med(sold.map { |a| a['pr'] }).round,
                       'us' => (u = med(sold.map { |a| a['us'] }.compact)) && u.round,
                       'sqm' => sqm.size >= 1 ? med(sqm).round : nil,
                       'items' => items.map { |a| a.reject { |x, _| %w[k cur sec loc].include?(x) || a[x].nil? } } }
        end
      end
      out[k] = res unless res.empty?
    end
    out
  end
end
