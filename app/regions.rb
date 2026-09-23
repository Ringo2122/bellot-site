# encoding: utf-8
# Регион из адреса: 6 областей + г. Минск. Общий для build.rb, market_realty.rb, collect_all.rb.
OBLAST = { 'брест' => 'Брестская', 'витебск' => 'Витебская', 'гомел' => 'Гомельская',
           'гродн' => 'Гродненская', 'могил' => 'Могилевская', 'минск' => 'Минская' }.freeze

# Площадки пишут адрес по-разному: "Витебская обл.", "г.Витебск", "Витебский район".
def region_of(addr)
  a = addr.to_s.tr('ё', 'е')
  return 'г. Минск' if a =~ /г\.?\s*Минск(?!ая)/
  [/(\S+?)ская\s+обл/i, /(\S+?)ский\s+(?:р-?н|район)/i].each do |re|
    m = a.match(re) or next
    k = OBLAST.keys.find { |x| m[1].downcase.start_with?(x[0, 5]) }
    return OBLAST[k] + ' область' if k
  end
  k = OBLAST.keys.find { |x| a.downcase.include?(x) }
  k ? OBLAST[k] + ' область' : a[/^[^,]+/].to_s.strip
end
