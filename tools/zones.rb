#!/usr/bin/env ruby
# encoding: utf-8
#
# Сетка экономико-планировочных зон Минска для расчёта аренды (app/zones.rb) из карты МГЦН:
#   https://mgcn.by/wp-content/uploads/2020/09/minsk-2016-zones-web.jpg (11 723 × 8 444, «действует с 01.10.2016»)
#   ruby tools/zones.rb карта.jpg   → app/zones.json   (запускать на Mac: уменьшение картинки — sips)
# Как устроено:
#   1. карту уменьшаем в 4 раза (≈10 м в точке; заливка между домами остаётся чистой) и читаем как BMP;
#   2. точку относим к зоне, только если её цвет — заливка зоны (COLORS, ±15; «9» — заливка вне зон: белый, серый,
#      зелёный); дома, дороги и надписи не совпадают ни с одной заливкой и в счёт не идут. По среднему цвету клетки
#      (как было сначала) 3-я зона в плотной застройке выходила 2-й — дома темнят жёлтый до коричневого;
#   3. клетка сетки (2×2 точки, ≈20 м) — зона большинства совпавших точек; клетки без совпадений (крупные здания,
#      широкие дороги) берут зону соседей;
#   4. привязка к координатам — по CTRL (tools/zones_ctrl.json): станции метро 1-й и 2-й линий — координаты из
#      OpenStreetMap, место на карте — середина значков входов «М»; аффинное преобразование методом наименьших
#      квадратов, невязки печатаем (29.09.2026: 5–49 м, значки стоят у входов, а не в центре станции).
#   PREVIEW=файл.bmp — сохранить раскраску сетки по зонам, чтобы сверить с картой глазами.
require 'json'
require 'tmpdir'

SRC = ARGV[0] or abort 'укажите карту: ruby tools/zones.rb minsk-2016-zones-web.jpg'
FULL_W = 11_723
# заливки зон на карте, уменьшенной в 4 раза (самый частый цвет вокруг точек внутри зоны): { "1": [[r,g,b], …], …, "9": вне зон }
COLORS = JSON.parse(File.read(File.join(__dir__, 'zones_colors.json')))
# опорные точки: [широта, долгота, x, y на полной карте]
CTRL = JSON.parse(File.read(File.join(__dir__, 'zones_ctrl.json')))

bmp = File.join(Dir.tmpdir, 'zones.bmp')
system('sips', '-s', 'format', 'bmp', '-Z', (FULL_W / 4).to_s, SRC, '--out', bmp, out: File::NULL) or abort 'sips не сработал'
b = File.binread(bmp)
off, pw, ph, bpp = b[10, 4].unpack1('V'), b[18, 4].unpack1('l<'), b[22, 4].unpack1('l<'), b[28, 2].unpack1('v')
step = bpp / 8
row = ((pw * bpp + 31) / 32) * 4
refs = COLORS.flat_map { |z, cs| cs.map { |c| [z.to_i, c] } }
label = lambda do |x, y|
  o = off + (ph.positive? ? ph - 1 - y : y) * row + x * step
  r, g, bl = b.getbyte(o + 2), b.getbyte(o + 1), b.getbyte(o)
  hit = refs.find { |_, c| (r - c[0])**2 + (g - c[1])**2 + (bl - c[2])**2 <= 15**2 }
  hit ? hit[0] : 0
end
bw, h = pw / 2, ph.abs / 2
grid = Array.new(h) do |y|
  Array.new(bw) do |x|
    v = [label.(2 * x, 2 * y), label.(2 * x + 1, 2 * y), label.(2 * x, 2 * y + 1), label.(2 * x + 1, 2 * y + 1)].select(&:positive?)
    v.empty? ? 0 : v.group_by(&:itself).max_by { |_, a| a.size }[0]
  end
end
# клетки без совпадений (здания, дороги, надписи) — зона большинства соседей в окне 5×5, пока есть что заполнять
15.times do
  changed = 0
  grid = grid.each_with_index.map do |r, y|
    r.each_with_index.map do |z, x|
      next z if z.positive?
      c = Hash.new(0)
      (-2..2).each { |dy| next if y + dy < 0 || !(rr = grid[y + dy]); (-2..2).each { |dx| v = rr[x + dx] if x + dx >= 0; c[v] += 1 if v && v.positive? } }
      next 0 if c.values.sum < 3
      changed += 1
      c.max_by { |_, n| n }[0]
    end
  end
  break if changed.zero?
end
grid = grid.map { |r| r.map { |z| z == 9 ? 0 : z } }   # вне зон
# привязка: x = a·lon + b·lat + c, y = d·lon + e·lat + f (в клетках сетки), МНК
def lsq(rows, ys)
  # нормальные уравнения 3×3
  m = Array.new(3) { Array.new(3, 0.0) }
  v = Array.new(3, 0.0)
  rows.each_with_index { |r, i| 3.times { |p| v[p] += r[p] * ys[i]; 3.times { |q| m[p][q] += r[p] * r[q] } } }
  3.times do |c|   # Гаусс
    piv = (c...3).max_by { |r| m[r][c].abs }
    m[c], m[piv] = m[piv], m[c]
    v[c], v[piv] = v[piv], v[c]
    (0...3).each do |r|
      next if r == c
      f = m[r][c] / m[c][c]
      3.times { |q| m[r][q] -= f * m[c][q] }
      v[r] -= f * v[c]
    end
  end
  (0...3).map { |i| v[i] / m[i][i] }
end
k = bw.to_f / FULL_W
rows = CTRL.map { |lat, lon, _, _| [lon, lat, 1.0] }
ax = lsq(rows, CTRL.map { |_, _, x, _| x * k })
ay = lsq(rows, CTRL.map { |_, _, _, y| y * k })
mpc = (111_320 * Math.cos(53.9 * Math::PI / 180) / ax[0]).abs   # метров в клетке
CTRL.each do |lat, lon, x, y, name|
  ex = ax[0] * lon + ax[1] * lat + ax[2] - x * k
  ey = ay[0] * lon + ay[1] * lat + ay[2] - y * k
  puts format('%-28s невязка %4.0f м', name, Math.hypot(ex, ey) * mpc)
end
rle = grid.map { |r| r.chunk_while { |a, c| a == c }.map { |g| "#{g[0]}#{g.size}" }.join(',') }
File.write(File.expand_path('../app/zones.json', __dir__),
           JSON.generate('src' => 'mgcn.by/mapzone (2016)', 'm' => mpc.round(1), 't' => ax + ay, 'rows' => rle))
cnt = grid.flatten.group_by(&:itself).transform_values(&:size)
puts "сетка #{bw}×#{h}, #{mpc.round(1)} м в клетке; клеток по зонам: #{cnt.sort.to_h}"
if ENV['PREVIEW']
  pal = { 0 => [255, 255, 255], 1 => [230, 90, 170], 2 => [200, 120, 50], 3 => [240, 220, 60], 4 => [80, 170, 220], 5 => [120, 80, 200] }
  rs = ((bw * 3 + 3) / 4) * 4
  data = grid.reverse.map { |r| r.map { |z| pal[z].reverse.pack('C3') }.join.ljust(rs, "\0") }.join
  File.binwrite(ENV['PREVIEW'], ['BM', 54 + data.size, 0, 54, 40, bw, h, 1, 24, 0, data.size, 2835, 2835, 0, 0].pack('a2VVVVl<l<vvVVl<l<VV') + data)
end
