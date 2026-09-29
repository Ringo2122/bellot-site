# encoding: utf-8
#
# БАВ — базовая арендная величина: по ней на сайте считается аренда в разделе «Право аренды».
# Меняется раз в год, с 1 апреля (постановление Совмина). Действующая сейчас — 20,03 руб. с 01.04.2026
# (постановление от 28.03.2026 № 142).
# Где проверяем:
#   • Госкомимущество (gki.gov.by) — новость «Установлен новый размер базовой арендной величины»: раз в сутки
#     смотрим первые страницы новостей;
#   • извещения МГЦН — в каждом посте аренды: «базовая арендная величина (БАВ) с 01.04.2026 составляет 20,03 рублей».
# Берём значение с самой поздней датой начала, которая уже наступила. Хранится в data/bav.json: v, from, src, url, checked.
require 'json'
require 'time'
require_relative 'store'
require_relative 'sources'

module Bav
  module_function

  FILE = File.join(Store::DATA, 'bav.json')
  GKI = 'https://www.gki.gov.by'
  SEED = { 'v' => 20.03, 'from' => '2026-04-01', 'src' => 'постановление Совета Министров от 28.03.2026 № 142 (Госкомимущество)',
           'url' => "#{GKI}/ru/about-press-news-ru/view/ustanovlen-novyj-razmer-bazovoj-arendnoj-velichiny-13348/" }.freeze

  def load
    File.exist?(FILE) ? JSON.parse(File.read(FILE, encoding: 'UTF-8')) : SEED.dup
  rescue JSON::ParserError
    SEED.dup
  end

  # новое значение принимаем, если его дата начала уже наступила и не раньше известной
  def offer(cur, v, from, src, url)
    return cur unless v.to_f.positive? && from && from <= Time.now.strftime('%Y-%m-%d') && from >= cur['from'].to_s
    return cur if from == cur['from'] && (v.to_f - cur['v'].to_f).abs < 0.005
    STDERR.puts "БАВ: #{cur['v']} с #{cur['from']} → #{v} с #{from} (#{src})"
    cur.merge('v' => v.to_f.round(2), 'from' => from, 'src' => src, 'url' => url)
  end

  # mg — [[«01.04.2026», 20.03, адрес поста], …] из постов МГЦН этого прогона
  def run(mg)
    cur = load
    mg.each { |d, v, u| cur = offer(cur, v, Time.strptime(d, '%d.%m.%Y').strftime('%Y-%m-%d'), 'извещение МГЦН', u) rescue nil }
    if Time.now.to_i - cur['checked'].to_i > 20 * 3600
      (1..3).each do |p|
        html = Src.get("#{GKI}/ru/about-press-news-ru/" + (p > 1 ? "page/#{p}" : '')) or break
        link = html[%r{href="(#{Regexp.escape(GKI)}/ru/about-press-news-ru/view/[^"]*bazovoj-arendnoj-velichiny[^"]*)"}, 1] or next
        t = Src.txt(Src.get(link).to_s)
        m = t.match(/с\s+1\s+апреля\s+(\d{4})\s+года\s+состав\S*\s+(\d+),(\d{2})/) or break
        cur = offer(cur, "#{m[2]}.#{m[3]}".to_f, "#{m[1]}-04-01", 'Госкомимущество', link)
        break
      end
      cur['checked'] = Time.now.to_i
    end
    File.write(FILE, JSON.generate(cur))
    cur
  end
end
