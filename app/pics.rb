# encoding: utf-8
#
# Все фото из карточки площадки — у лотов, собранных до 26.09.2026 (у новых фото пишутся сразу, в new_lot).
# Перечитываем страницу лота и берём галерею (Src.photos): сначала активные, потом архив от свежих к старым.
# За прогон — не дольше PICS_MIN минут и не больше PICS_CAP лотов; площадки — параллельно, каждая со своей паузой.
# У лота — pics: [ссылки на фото площадки]. Пустой список — фото на площадке нет (или страница уже удалена).
# У лотов konfiskat в архиве страница konfiskat.by исчезает — берём страницу торгов torgikonfiskat.by (tk).

PICS_CAP = (ENV['PICS_CAP'] || 1500).to_i
PICS_MIN = (ENV['PICS_MIN'] || 15).to_f
PICS_PAUSE = { 'konfiskat.by' => 1.5, 'belauction.by' => 2 }.freeze

def fill_pics(db, stat)
  stop = Time.now + PICS_MIN * 60
  todo = db.values.reject { |l| l.key?('pics') || l['pics_try'].to_i >= 2 || PLAT_OFF.include?(l['platform']) }
  todo = todo.sort_by { |l| [l['status'] == 'active' ? 0 : 1, -(l['closed'] || l['req_to']).to_i] }.first(PICS_CAP)
  return if todo.empty?
  mx = Mutex.new
  todo.group_by { |l| l['platform'] }.map do |plat, ls|
    Thread.new do
      ls.each do |l|
        break if Time.now > stop
        url = plat == 'konfiskat.by' && l['status'] == 'archive' && l['tk'] ? l['tk'] : l['url']
        html = Src.get(url)
        mx.synchronize do
          if html
            l['pics'] = Src.photos(plat, html, url[%r{\Ahttps?://[^/]+}])
            l.delete('pics_try')
            stat['фото из карточки: дозаполнено'] += 1
          else
            l['pics_try'] = l['pics_try'].to_i + 1
          end
        end
        sleep PICS_PAUSE[plat] || 0.5
      end
    rescue StandardError => e
      STDERR.puts "фото #{plat}: ошибка #{e.message}"
    end
  end.each(&:join)
  left = db.values.count { |l| !l.key?('pics') && l['pics_try'].to_i < 2 }
  STDERR.puts "фото из карточек: дозаполнено #{stat['фото из карточки: дозаполнено']}, осталось #{left}"
end
