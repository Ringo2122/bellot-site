# encoding: utf-8
#
# Экономико-планировочные зоны Минска → коэффициент местонахождения для расчёта аренды (Указ № 138):
# решение Мингорисполкома от 07.09.2023 № 3716 — зона 1 → 1,0; 2 → 0,9; 3 → 0,8; 4 → 0,7; 5 → 0,6.
# Границы зон — карта МГЦН «Минск, экономико-планировочные зоны» (mgcn.by/mapzone, действует с 01.10.2016),
# переведённая в сетку зон (tools/zones.rb → app/zones.json) и привязанная к координатам по станциям метро
# и развязкам МКАД. Точка лота — из geo.rb. Зону называем, только если вокруг точки одна зона:
#   дом найден (a) — смотрим круг ~60 м, найдена только улица (s) — ~300 м; у границы зон или без точки — диапазон.
require 'json'

module Zones
  module_function

  K = { 1 => 1.0, 2 => 0.9, 3 => 0.8, 4 => 0.7, 5 => 0.6 }.freeze
  ALL = { 'rng' => [0.6, 1.0] }.freeze

  def map
    @map ||= begin
      j = JSON.parse(File.read(File.join(__dir__, 'zones.json')))
      j['grid'] = j['rows'].map { |r| r.scan(/(\d)(\d+),?/).flat_map { |z, n| [z.to_i] * n.to_i } }
      j
    end
  end

  # [широта, долгота] → [x, y] клетки сетки
  def px(lat, lon)
    a = map['t']
    [(a[0] * lon + a[1] * lat + a[2]).round, (a[3] * lon + a[4] * lat + a[5]).round]
  end

  def zone(x, y)
    g = map['grid']
    y.between?(0, g.size - 1) && x.between?(0, g[y].size - 1) ? g[y][x] : 0
  end

  # geo — [широта, долгота, точность] из geo.rb
  def at(geo)
    return ALL.merge('why' => 'точка на карте не найдена') unless geo.is_a?(Array)
    return ALL.merge('why' => 'адрес найден только до населённого пункта') if geo[2] == 'p'
    x, y = px(geo[0], geo[1])
    r = (geo[2] == 'a' ? 60 : 300) / map['m'].to_f   # радиус в клетках (m — метров в клетке)
    cnt = Hash.new(0)
    (-r.ceil..r.ceil).each do |dy|
      (-r.ceil..r.ceil).each do |dx|
        next if dx * dx + dy * dy > r * r
        z = zone(x + dx, y + dy)
        cnt[z] += 1 if z.positive?
      end
    end
    # пятна застройки другого оттенка внутри зоны — не граница: считаем зоны, занимающие хотя бы четверть круга
    zs = cnt.select { |_, n| n >= cnt.values.sum / 4.0 }.keys
    return ALL.merge('why' => 'вне карты зон') if zs.empty?
    return { 'z' => zs[0], 'k' => K[zs[0]] } if zs.size == 1
    ks = zs.map { |z| K[z] }
    { 'rng' => ks.minmax, 'why' => "объект у границы зон #{zs.sort.join(' и ')}" }
  end
end
