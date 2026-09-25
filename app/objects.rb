# encoding: utf-8
#
# Что за объект у лота — для сравнения с завершёнными торгами и истории объекта (similar.rb).
#   Недвижимость: категория по названию (квартиры, дома, склады…) и населённый пункт.
#   Транспорт и спецтехника: марка, модель, год выпуска — из полей площадки («Марка», «Модель»,
#   «Марка (модель)», «Год выпуска», «Год»), иначе из названия.
#   Идентификаторы: VIN, кадастровый номер, инвентарный номер ЕГРНИ (500/C-37246) — по ним узнаём
#   тот же объект на повторных торгах, в том числе на другой площадке.
# Категории недвижимости — те же, что в аналитике (stats.js, kindOf), плюс «жилое помещение» к квартирам.
require_relative 'regions'

module Obj
  module_function

  B = '(?<![а-яёa-z0-9])'   # граница слова: \b в Ruby не работает с кириллицей
  E = '(?![а-яёa-z0-9])'
  # порядок важен: «доля в жилом доме» — доля, «право аренды склада» — аренда
  REALTY = [['квартир|жилое помещение|комнат', 'Квартиры'], ['доля|доли', 'Доли'], ['машино-?мест|гараж', 'Гаражи и машино-места'],
            ['аренд', 'Право аренды'], ["жилой дом|жилого дома|коттедж|#{B}дом#{E}", 'Жилые дома'], ['дач|садов', 'Дачи и садовые домики'],
            ['незаверш', 'Незавершённое строительство'], ['земельн|участ', 'Земельные участки'], ['магазин|торгов', 'Торговые объекты'],
            ['склад|хранилищ', 'Склады'], ['офис|административ', 'Офисы'], ['производ|цех|завод|мастерск', 'Производственные'],
            ['комплекс', 'Комплексы'], ['помещени', 'Помещения'], ['здани|строени|сооружени', 'Здания и сооружения']]
           .map { |re, t| [Regexp.new(re), t] }.freeze

  BRANDS = [
    # легковые
    ['volkswagen|фольксваген|vw', 'VOLKSWAGEN'], ['audi|ауди', 'AUDI'], ['bmw|бмв', 'BMW'], ['mercedes|мерседес', 'MERCEDES-BENZ'],
    ['opel|опель', 'OPEL'], ['ford|форд', 'FORD'], ['renault|рено', 'RENAULT'], ['peugeot|пежо', 'PEUGEOT'], ['citroen|ситроен', 'CITROEN'],
    ['toyota|тойота', 'TOYOTA'], ['nissan|ниссан', 'NISSAN'], ['mazda|мазда', 'MAZDA'], ['kia|киа', 'KIA'], ['hyundai|хендай|хундай|хендэ|хюндай', 'HYUNDAI'],
    ['skoda|шкода', 'SKODA'], ['lada|лада|ваз|vaz', 'LADA'], ['geely|джили', 'GEELY'], ['chevrolet|шевроле', 'CHEVROLET'],
    ['mitsubishi|митсубиси|мицубиси', 'MITSUBISHI'], ['honda|хонда', 'HONDA'], ['volvo|вольво', 'VOLVO'], ['fiat|фиат', 'FIAT'],
    ['daewoo|дэу', 'DAEWOO'], ['subaru|субару', 'SUBARU'], ['suzuki|сузуки', 'SUZUKI'], ['lexus|лексус', 'LEXUS'],
    ['land rover|range rover|ленд ровер', 'LAND ROVER'], ['chery|чери', 'CHERY'], ['haval|хавейл', 'HAVAL'], ['belgee|белджи', 'BELGEE'],
    ['seat', 'SEAT'], ['dacia|дачия', 'DACIA'], ['infiniti|инфинити', 'INFINITI'], ['porsche|порше', 'PORSCHE'], ['jeep|джип', 'JEEP'],
    ['chrysler|крайслер', 'CHRYSLER'], ['dodge|додж', 'DODGE'], ['saab|сааб', 'SAAB'], ['ssangyong|ссангйонг|санг ёнг', 'SSANGYONG'],
    ['great wall', 'GREAT WALL'], ['lifan|лифан', 'LIFAN'], ['москвич|moskvich', 'MOSKVICH'], ['иж|izh', 'IZH'], ['заз|zaz', 'ZAZ'],
    ['уаз|uaz', 'UAZ'], ['газ|gaz', 'GAZ'],
    # грузовые, автобусы, прицепы
    ['маз|maz', 'MAZ'], ['камаз|kamaz', 'KAMAZ'], ['man|ман', 'MAN'], ['daf|даф', 'DAF'], ['scania|скания', 'SCANIA'], ['iveco|ивеко', 'IVECO'],
    ['зил|zil', 'ZIL'], ['isuzu|исузу', 'ISUZU'], ['паз|paz', 'PAZ'], ['лиаз|liaz', 'LIAZ'], ['неман|neman', 'NEMAN'], ['ikarus|икарус', 'IKARUS'],
    ['neoplan|неоплан', 'NEOPLAN'], ['setra|сетра', 'SETRA'], ['schmitz|шмитц|шмиц', 'SCHMITZ'], ['krone|кроне', 'KRONE'],
    ['kogel|kögel|когель', 'KOGEL'], ['wielton|вielton|виелтон', 'WIELTON'], ['tatra|татра', 'TATRA'], ['howo|хово|sinotruk|синотрук', 'HOWO'],
    ['shacman|шакман', 'SHACMAN'], ['faw|фав', 'FAW'], ['foton|фотон', 'FOTON'], ['jac', 'JAC'], ['dongfeng|донгфенг', 'DONGFENG'],
    # спецтехника
    ['мтз|беларус|belarus', 'MTZ'], ['амкодор|amkodor', 'AMKODOR'], ['jcb', 'JCB'], ['caterpillar|cat', 'CAT'], ['komatsu|комацу', 'KOMATSU'],
    ['hitachi|хитачи', 'HITACHI'], ['liebherr|либхерр', 'LIEBHERR'], ['john deere|джон дир', 'JOHN DEERE'], ['claas|клаас', 'CLAAS'],
    ['гомсельмаш|полесье|gomselmash', 'GOMSELMASH'], ['doosan|дусан', 'DOOSAN'], ['bobcat|бобкэт', 'BOBCAT'], ['юмз|ymz', 'YUMZ'],
    ['кировец', 'KIROVETS']
  ].map { |re, t| [Regexp.new("#{B}(?:#{re})#{E}"), t] }.freeze

  # площадки пишут латинские марки с русскими буквами («МITSUBISHI», «МAZ»): в словах с латиницей русские двойники — в латиницу
  HOMO = { 'а' => 'a', 'в' => 'b', 'е' => 'e', 'к' => 'k', 'м' => 'm', 'н' => 'h', 'о' => 'o', 'р' => 'p', 'с' => 'c', 'т' => 't', 'у' => 'y', 'х' => 'x' }.freeze
  TR = { 'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e', 'ж' => 'zh', 'з' => 'z', 'и' => 'i', 'й' => 'i', 'к' => 'k',
         'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's', 'т' => 't', 'у' => 'u', 'ф' => 'f', 'х' => 'h',
         'ц' => 'c', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'sch', 'ъ' => '', 'ы' => 'y', 'ь' => '', 'э' => 'e', 'ю' => 'yu', 'я' => 'ya' }.freeze

  def low(s)
    s.to_s.downcase.tr('ё', 'е').gsub(/[a-zа-я]+/) { |w| w =~ /[a-z]/ && w =~ /[а-я]/ ? w.gsub(/[авекмнорстух]/) { |c| HOMO[c] } : w }
  end

  def rows_of(secs)
    (secs || []).flat_map { |s| s['rows'] || [] }
  end

  def row(rows, re)
    (rows.find { |k, v| k.to_s =~ re && !v.to_s.strip.empty? } || [])[1]
  end

  # ── недвижимость ──
  def realty_kind(name)
    n = low(name)
    (REALTY.find { |re, _| n =~ re } || [])[1]
  end

  PLACE = /(?:^|[\s,(])(г\.\s?п\.|гп\.|г\.|город|а\.\s?г\.|аг\.|агрогородок|дер\.|д\.|деревня|пос\.|п\.|поселок|х\.|хутор)\s*([А-Я][а-я]+(?:-[А-Яа-я][а-я]+)?)/

  # населённый пункт: «г|пинск»; деревни и агрогородки — с областью и районом: «н|Минская область|минск|ратомка»
  def city(loc, name = nil)
    [loc, name].each do |s|
      s = s.to_s.tr('ё', 'е').tr('Ё', 'Е')
      m = s.match(PLACE) or next
      town = m[2].downcase
      return "г|#{town}" if m[1] =~ /\A(?:г\.\s?п\.|гп\.|г\.|город)\z/
      dist = s[/([А-Я][а-я]+?)(?:ский|цкий|ской)\s+(?:р-н|район)/, 1].to_s.downcase
      return "н|#{region_of(s)}|#{dist}|#{town}"
    end
    nil
  end

  def town_name(key)
    key && key.split('|').last.split('-').map(&:capitalize).join('-')
  end

  # ── транспорт ──
  def brand(text)
    t = low(text)
    BRANDS.each { |re, canon| (m = t.match(re)) && (return [canon, m]) }
    nil
  end

  def norm_model(tok)
    t = tok.to_s.gsub(/[а-я]/) { |c| TR[c] }.upcase.gsub(/[^A-Z0-9]/, '')
    return nil if t.empty? || t =~ /\A(?:19|20)\d\d\z/
    t =~ /\A\d/ ? t[/\A\d+/][0, 4] : t
  end

  # модель — первое слово после марки: «Mercedes-Benz E 220» → E220, «МАЗ-5440А9» → 5440, «Lada-Ваз, 2108» → 2108
  def model_after(text, m)
    model_from(low(text)[m.end(0)..-1].to_s.sub(/\A[\s,\-–()]*(?:benz|бенц|ваз|vaz|lada|лада|motors?|моторс)?[\s,\-–()]*/, ''))
  end

  # «as 440» и «as440» — одна модель: короткие буквы с числом склеиваем
  def model_from(rest)
    rest = rest.to_s.sub(/\A[\s,\-–()]+/, '')
    if (x = rest.match(/\A([a-zа-я]{1,2})[\s-]?(\d{2,4})(?!\d)/))
      return norm_model(x[1] + x[2])
    end
    norm_model(rest[/\A[a-zа-я0-9]+/])
  end

  def year_of(rows, name)
    y = row(rows, /\AГод(?: выпуска)?\z/).to_s[/(?:19|20)\d\d/]
    y ||= name.to_s[/((?:19[5-9]|20[0-3])\d)\s*(?:г\.?\s*в|года|г\.)/, 1]
    y ||= name.to_s[/,\s*((?:19[5-9]|20[0-3])\d)\s*(?:,|\z)/, 1]
    y && y.to_i
  end

  def vehicle(l, rows)
    b = m = nil
    if (bt = row(rows, /\AМарка(?: \(модель\))?\z/))
      if (x = brand(bt))
        b = x[0]
        md = row(rows, /\AМодель\z/)
        m = md ? model_from(low(md)) : model_after(bt, x[1])
      end
    end
    if !b || !m
      x = brand(l['name']) or return nil
      b ||= x[0]
      m ||= model_after(l['name'], x[1])
    end
    y = year_of(rows, l['name'])
    b && m && y ? { 'b' => b, 'm' => m, 'y' => y } : nil
  end

  # ── идентификаторы объекта ──
  def lat(c)
    { 'С' => 'C', 'с' => 'C', 'Д' => 'D', 'д' => 'D' }[c] || c.upcase
  end

  def ids(name, rows)
    t = ([name] + rows.map { |k, v| "#{k}: #{v}" }).join(' ')
    out = []
    t.scan(/(?<![A-Za-z0-9])([A-HJ-NPR-Za-hj-npr-z0-9]{17})(?![A-Za-z0-9])/) { |(v)| out << "vin:#{v.upcase}" if v =~ /\d/ && v =~ /[a-z]/i }
    t.scan(/(?<!\d)(\d{18})(?!\d)/) { |(k)| out << "kad:#{k}" }
    t.scan(%r{(?<!\d)(\d{3})\s*/\s*([CСDДcсdд])\s*-\s*(\d{3,})}) { |a, c, n| out << "inv:#{a}/#{lat(c)}-#{n}" }
    out.uniq
  end

  # konfiskat: где стоит машина — «На хранении: РУП Белтаможсервис - Гродненская область, Вороновский район…»
  def storage(rows)
    d = row(rows, /\AОписание\z/).to_s
    s = d[/(?:На хран\S*|Место хранения|Находится по адресу)[:\s]+(.+?)(?:\s+Осмотр|\.\s|\z)/, 1] or return nil
    s = s.sub(/\A.*?\s[-–]\s/, '')
    region_of(s) =~ /обл|Минск/ ? s[0, 160] : nil
  end
end
