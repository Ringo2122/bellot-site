# encoding: utf-8
#
# Архив площадок: завершённые за BACK_DAYS дней торги, которых у нас нет, — сразу в архив сайта с итогами.
# Нужно аналитике продаж: робот собирает итоги с 25.09.2026, а площадки хранят завершённые торги и раньше.
#   e-auction.by  вкладка «Завершённые» разделов (?type=f)
#   ipmtorgi.by   список раздела — он продолжается архивом
#   beltorgi.by   каталог с фильтром «состоявшиеся» и «несостоявшиеся»
#   konfiskat.by  каталог торгов torgikonfiskat.by («Завершены» и «Архив»)
#   belauction.by первые страницы «Проданные лоты» (≈ месяц) и «Завершённые аукционы» (≈ 10 дней) — дальше robots.txt не пускает
#   minskestate.by список раздела — в нём и завершённые торги со статусом («Продано», «Торги не состоялись»)
#   auction24.by  список аукционов /auction (от поздних к ранним) → страницы аукционов за месяц → завершённые лоты
#   lotsale.by    API завершённых торгов /auctions/public/completed (от поздних к ранним)
#   butb.by       «Архив торгов» биржи (archiveAuctions.xhtml) страницами по 100, от поздних торгов к ранним
# mgcn.by (очные аукционы МГЦН) — итогов онлайн нет, архив площадки не собираем
# Правила те же, что для новых лотов: разделы площадок, минимальная цена по разделу, выключенные площадки.
# За прогон — не больше BACK_CAP лотов с площадки и не дольше BACK_MIN минут: первый месяц загрузится
# за несколько прогонов, дальше добираются только пропущенные. Лот из архива помечен bf (время загрузки),
# даты появления у него нет — в «новые лоты» аналитики он не попадает.
# Отброшенные после проверки (дешевле порога, старше месяца, уже известны по konfiskat.by) — в data/backfill_skip.json:
# второй раз их страницы не открываем (25.09: без этого прогон тратил всё время на 400 уже известных машин konfiskat).
# Вызывается из update.rb после итогов торгов: там же определены new_lot, trim, ipm_kind, kf_kind.
#
# Архив за год (YEAR_ARCH=1 — ночной прогон .github/workflows/archive.yml, решение Артёма 02.10.2026): те же задания
# на 365 дней назад, до 4,5 часа за ночь, без ограничения числа лотов. Глубина площадок (02.10): e-auction, ИПМ,
# beltorgi, torgikonfiskat — год и больше; konfiskat берём только за YEAR_KF_DAYS = 3 месяца (решение Артёма 02.10:
# за год ≈ 9 тыс. машин, 1 200 страниц списка по 8, у старых площадка удалила фото);
# auction24 хранит торги только с 03.04.2026; minskestate — всё на одной странице раздела; lotsale — ≈ 100 торгов в год;
# butb — архив биржи с 2016 г. (≈ 1,5 тыс. лотов в год, у каждого — страница лота и фото). Не берём: «Оборудование»
# (архив раздела — только за месяц), belauction.by (robots.txt — только первые страницы, ≈ месяц), mgcn.by (итогов нет).
# Фото: главное — 320 px (≈ 12 КБ, только для карточки; 400 px — ≈ 22 КБ), в галерее — до 5 фото ссылками на площадку:
# 5 фото × 20 тыс. лотов своими файлами — 2–5 ГБ, больше лимита GitHub Pages (1 ГБ). Скачать их — после переезда на свой сервер.
# Площадка, чей список пройден до конца за отведённое время, отмечается в data/backfill_year.json и больше не обходится.
YEAR_ARCH = !ENV['YEAR_ARCH'].to_s.empty?
YEAR_DONE = File.join(Store::DATA, 'backfill_year.json')
YEAR_PLATS = %w[e-auction.by ipmtorgi.by beltorgi.by konfiskat.by minskestate.by auction24.by lotsale.by butb.by].freeze
YEAR_PH = [320, 40].freeze   # ширина и качество главного фото
YEAR_PICS = 5
YEAR_KF_DAYS = 90
# По расписанию — только ночью: GitHub запускает расписание с опозданием (04.10 — в 05:43 вместо 23:30; архив шёл до 10:15,
# обход 9:00 час ждал в очереди). Ночной прогон работает до 6:30 по Минску (TZ в workflow), запуск вручную — без ограничения.
YEAR_UNTIL = if YEAR_ARCH && ENV['GITHUB_EVENT_NAME'] == 'schedule'
               t = Time.now
               if t.hour >= 22 then Time.local(t.year, t.month, t.day, 6, 30) + 86_400
               elsif t.hour < 7 then Time.local(t.year, t.month, t.day, 6, 30)
               else t   # днём не работаем
               end
             end

BACK_DAYS = (ENV['BACK_DAYS'] || (YEAR_ARCH ? 365 : 30)).to_i
BACK_CAP = (ENV['BACK_CAP'] || (YEAR_ARCH ? 1_000_000 : 350)).to_i
BACK_MIN = (ENV['BACK_MIN'] || (YEAR_ARCH ? 270 : 25)).to_f
BACK_SKIP = File.join(Store::DATA, 'backfill_skip.json')

def year_done
  File.exist?(YEAR_DONE) ? (JSON.parse(File.read(YEAR_DONE, encoding: 'UTF-8')) rescue {}) : {}
end

# площадки, чей архив за год ещё не загружен
def year_left
  YEAR_PLATS - year_done.keys - PLAT_OFF
end

def back_min_ok?(sec, price)
  min = MINP[sec].to_f
  !(min.positive? && price.to_f.positive? && price < min)
end

# карточка + страница лота + итог → запись архива
def back_rec(c, sec, d, r, src, now)
  rec = new_lot(c, sec, d, src, now)
  rec['price'] = r['start'] if r['start'].to_f.positive?   # в архиве площадки часто показывают цену продажи
  rec.delete('first_seen')
  rec.merge!('status' => 'archive', 'closed' => rec['req_to'], 'why' => 'deadline', 'bf' => now,
             'prices' => [[rec['req_to'], rec['price']]], 'result' => r.merge('checked' => now, 'tries' => 1))
end

def backfill(db, stat, pstat, now)
  since = now - BACK_DAYS * 86_400
  stop = [Time.now + BACK_MIN * 60, YEAR_UNTIL].compact.min
  mx = Mutex.new
  known = ->(k) { mx.synchronize { db.key?(k) } }
  skip = File.exist?(BACK_SKIP) ? (JSON.parse(File.read(BACK_SKIP, encoding: 'UTF-8')) rescue {}) : {}
  skip.reject! { |_, (t, _)| t.to_i < since - 10 * 86_400 }
  # «old» — старше месяца: для архива за год такие лоты не отброшены (02.10: из-за них beltorgi останавливался на 37-м дне);
  # старше года — «old-y»
  old_tag = YEAR_ARCH ? 'old-y' : 'old'
  skipped = ->(k) { mx.synchronize { (w = skip[k] && skip[k][1]) == 'old' && YEAR_ARCH ? nil : w } }   # причина или nil
  drop = ->(k, why) { mx.synchronize { skip[k] = [now, why] } }
  add = lambda do |rec, d, photo|
    Store.save_details(rec['key'], trim(d['details'] || []))
    rec['photo'] = Store.save_photo(photo, rec['key'], Src::UA, *(YEAR_ARCH ? YEAR_PH : []))
    rec['pics'] = rec['pics'].first(YEAR_PICS) if YEAR_ARCH && rec['pics']
    mx.synchronize do
      db[rec['key']] = rec
      stat['архив площадок: добавлено'] += 1
      pstat[rec['platform']]['backfill'] += 1
    end
  end
  jobs = {
    'e-auction.by' => lambda do |left|
      PLAN['e-auction.by'].each do |path, sec|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec == 'oborud'
        Src.ea_list(path, since: since).each do |c|
          break if left.zero? || Time.now > stop
          next if known.(c['key']) || skipped.(c['key']) || !c['eid']
          info = Res.ea_info(c['eid'])
          r = Res.ea_result(info) or next
          next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'])
          html = Src.get(c['url']) or next
          d = Src.ea_detail(html)
          rec = back_rec(c, sec, d, r, "e-auction.by #{path}", now)
          rec['eid'] = c['eid']
          rec['torg'] = Res.ea_torg(info) || rec['torg']
          add.(rec, d, [d['photo_url'], c['thumb']])
          left -= 1
          sleep 0.4
        end
      end
    end,
    'ipmtorgi.by' => lambda do |left|
      PLAN['ipmtorgi.by'].each do |path, sec0|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec0 == 'oborud'
        Src.ipm_list(path, since: since).each do |c|
          break if left.zero? || Time.now > stop
          next if known.(c['key']) || skipped.(c['key'])
          sec = sec0 || ipm_kind(c['name'])
          html = Src.get(c['url']) or next
          all = Res.ipm_all_bids(html)
          r = Res.ipm_result(html, all)
          next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'] || c['price'])
          d = Src.ipm_detail(html)
          add.(back_rec(c, sec, d, r, "ipmtorgi.by #{path}", now), d, [d['photo_url'], c['thumb']])
          left -= 1
          sleep 0.4
        end
      end
    end,
    'beltorgi.by' => lambda do |left|
      PLAN['beltorgi.by'].each do |slug, sec|
        break if left.zero? || Time.now > stop
        next if YEAR_ARCH && sec == 'oborud'
        Src::BT_DONE.each_value do |status|
          old = 0   # каталог — по дате аукциона от поздних к ранним: пять старых подряд — дальше только старше
          (1..30).each do |p|
            cards = Src.bt_page(slug, p, status) or break
            cards.each do |c|
              break if left.zero? || Time.now > stop || old >= 5
              next if known.(c['key'])
              case skipped.(c['key'])
              when 'old', 'old-y' then old += 1; next
              when 'min' then next
              end
              html = Src.get(c['url']) or next
              r = Res.bt_result(html) or next   # перевыставлен — это уже новые торги
              d = Src.bt_detail(html)
              when_ = r['at'] || d['torg'] || d['req_to']
              if when_.to_i < since
                old += 1
                drop.(c['key'], old_tag)
                next
              end
              old = 0
              next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'])
              c['price'] = r['start'] if r['start'].to_f.positive?
              add.(back_rec(c, sec, d, r, "beltorgi.by #{slug}", now), d, [c['thumb']])
              left -= 1
              sleep 0.4
            end
            break if cards.size < 80 || left.zero? || Time.now > stop || old >= 5
            sleep 0.6
          end
        end
      end
    end,
    'belauction.by' => lambda do |left|
      Src.ba_list(:done).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key'])
        next drop.(c['key'], old_tag) if c['closed_day'].to_i < since
        sleep 2
        html = Src.get(c['url']) or next
        r = Res.ba_result(html)
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['price'] || c['price'])
        d = Src.ba_detail(html)
        add.(back_rec(c, c['sec'], d, r, 'belauction.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'minskestate.by' => lambda do |left|
      # список раздела — и активные, и завершённые; дата в карточке — дата аукциона
      Src.me_list.each do |c|
        break if left.zero? || Time.now > stop
        next if c['status'] !~ /Продан|не состоял|Отмен/i || known.(c['key']) || skipped.(c['key'])
        next drop.(c['key'], old_tag) if c['day'].to_i < since
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.me_result(html)
        next if r['st'] == 'pending'
        sec = c['sec'] || ipm_kind(c['name'])
        next if YEAR_ARCH && sec == 'oborud'
        next drop.(c['key'], 'min') unless back_min_ok?(sec, r['start'] || c['price'])
        d = Src.me_detail(html)
        add.(back_rec(c, sec, d, r, 'minskestate.by архив', now), d, [])   # фото — ссылками: robots.txt площадки закрывает их для роботов
        left -= 1
      end
    end,
    'auction24.by' => lambda do |left|
      # аукционы за месяц по списку /auction, их завершённые лоты; раздел — по названию (a24_sec)
      Src.a24_done(since).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || (YEAR_ARCH && c['sec'] == 'oborud')
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.a24_result(html)
        next if r['st'] == 'pending'
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['start'] || c['price'])
        d = Src.a24_detail(html)
        add.(back_rec(c, c['sec'], d, r, 'auction24.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'lotsale.by' => lambda do |left|
      Src.ls_done(since).each do |id|
        break if left.zero? || Time.now > stop
        key = "ls-#{id}"
        next if known.(key) || skipped.(key)
        sleep 0.5
        d = Src.ls_lot(id) or next
        next if YEAR_ARCH && d['sec'] == 'oborud'
        r = Res.ls_result(d['a'])
        next if r['st'] == 'pending'
        next drop.(key, 'min') unless back_min_ok?(d['sec'], r['start'] || d['price_byn'])
        c = Src.ls_card({ 'id' => id, 'lotName' => d['name'], 'price' => d['price_byn'],
                          'applicationDeadlineOnUtc' => d['a']['applicationDeadlineOnUtc'] }, d)
        add.(back_rec(c, d['sec'], d, r, 'lotsale.by архив', now), d, [d['photo_url']])
        left -= 1
      end
    end,
    'butb.by' => lambda do |left|
      # архив биржи от поздних торгов к ранним; раздел — по категории в карточке лота (bu_sec)
      Src.bu_done(since, stop).each do |c|
        break if left.zero? || Time.now > stop
        next if known.(c['key']) || skipped.(c['key']) || c['status'] !~ /состоявш|результативн|отмен|продан/i
        sleep 1
        html = Src.get(c['url']) or next
        r = Res.bu_result(html)
        next if r['st'] == 'pending'
        d = Src.bu_detail(html)
        next if YEAR_ARCH && d['sec'] == 'oborud'
        next drop.(c['key'], 'min') unless back_min_ok?(d['sec'], r['start'] || c['price'])
        c['name'] = d['name'] unless d['name'].to_s.empty?
        c['req_to'] ||= d['torg'] || c['day']   # у завершённых срока заявок на странице уже нет — берём дату торгов
        add.(back_rec(c, d['sec'], d, r, 'butb.by архив', now), d, [d['photo_url'], c['thumb']])   # фото — сразу: ссылки временные
        left -= 1
      end
    end,
    'konfiskat.by' => lambda do |left|
      # тот же лот мы могли знать по konfiskat.by: «Лот №» совпадает с номером лота там
      arts = mx.synchronize { db.values.select { |l| l['platform'] == 'konfiskat.by' }.to_h { |l| [l['art'].to_s, l] } }
      tks = mx.synchronize { db.values.map { |l| l['tk'].to_s[%r{/(\d+)/?\z}, 1] }.compact.to_h { |a| [a, true] } }
      Src.tk_archive(YEAR_ARCH ? [since, now - YEAR_KF_DAYS * 86_400].max : since, stop).each do |c|
        break if left.zero? || Time.now > stop
        key = "kf-tk#{c['tk_id']}"
        next if tks[c['tk_id']] || known.(key) || skipped.(key)
        sleep 1
        html = Src.get(c['url']) or next
        d = Src.tk_detail(html)
        if (mine = arts[d['art'].to_s])
          # тот же лот мы знаем по konfiskat.by — запоминаем ему ссылку на торги (по ней и итоги)
          mx.synchronize { mine['tk'] ||= c['url'] }
          next drop.(key, 'known')
        end
        r = Res.tk_result(html)
        rows = (d['details'].first || { 'rows' => [] })['rows']
        type = (rows.assoc('Тип транспорта') || [])[1].to_s
        sec = type =~ /груз|автобус|прицеп|тягач|специальн/i ? 'gruz' : kf_kind(d['title'].to_s + ' ' + c['name'])
        next drop.(key, 'min') unless back_min_ok?(sec, r['start'])
        # «На храненни: РУП Белтаможсервис - Гродненская область, Вороновский район…» — где стоит машина
        store = (rows.assoc('Описание') || [])[1].to_s[/На хран\S*:?\s*(.+?)(?:\s+Осмотр|\z)/, 1]
        loc = store && region_of(store) =~ /обл|Минск/ ? store.sub(/\A.*?\s[-–]\s/, '')[0, 160] : nil
        day = c['day'].to_i
        req = Time.at(day - 86_400).then { |t| Time.local(t.year, t.month, t.day, 12, 0).to_i }   # заявки — до 12:00 накануне
        price = r['start'].to_f.positive? ? r['start'] : c['price']
        rec = { 'key' => key, 'status' => 'archive', 'src' => 'konfiskat.by torgikonfiskat', 'last_seen' => now, 'bf' => now,
                'art' => d['art'] || c['tk_id'], 'name' => d['title'].to_s.empty? ? c['name'] : d['title'],
                'price' => price, 'prices' => [[req, price]], 'req_to' => req, 'torg' => day, 'url' => c['url'], 'tk' => c['url'],
                'location' => loc, 'region' => loc && region_of(loc), 'debtor' => 'Конфискованное имущество',
                'platform' => 'konfiskat.by', 'section' => sec, 'section_ru' => SEC_RU[sec], 'terms' => {},
                'closed' => req, 'why' => 'deadline', 'result' => r.merge('checked' => now, 'tries' => 1), 'pics' => d['photos'] || [] }
        add.(rec, d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end
  }
  done = year_done
  jobs.select! { |plat, _| year_left.include?(plat) } if YEAR_ARCH
  jobs.reject { |plat, _| PLAT_OFF.include?(plat) }.map do |plat, job|
    Thread.new do
      job.call(BACK_CAP)
      if YEAR_ARCH && Time.now < stop && pstat[plat]['backfill'] < BACK_CAP   # список пройден до конца, а не упёрся в лимит
        mx.synchronize { done[plat] = now }
        STDERR.puts "архив площадки #{plat} за год загружен"
      end
    rescue StandardError => e
      STDERR.puts "архив площадки #{plat}: ошибка #{e.message}"
    end
  end.each(&:join)
  File.write(BACK_SKIP, JSON.generate(skip))
  File.write(YEAR_DONE, JSON.generate(done)) if YEAR_ARCH
  STDERR.puts "архив площадок за #{BACK_DAYS} дн.: добавлено #{stat['архив площадок: добавлено']}" \
              "#{Time.now > stop ? ' (время прогона вышло — остальное в следующий раз)' : ''}"
end
