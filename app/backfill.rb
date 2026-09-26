# encoding: utf-8
#
# Архив площадок: завершённые за BACK_DAYS дней торги, которых у нас нет, — сразу в архив сайта с итогами.
# Нужно аналитике продаж: робот собирает итоги с 25.09.2026, а площадки хранят завершённые торги и раньше.
#   e-auction.by  вкладка «Завершённые» разделов (?type=f)
#   ipmtorgi.by   список раздела — он продолжается архивом
#   beltorgi.by   каталог с фильтром «состоявшиеся» и «несостоявшиеся»
#   konfiskat.by  каталог торгов torgikonfiskat.by («Завершены» и «Архив»)
#   belauction.by первые страницы «Проданные лоты» (≈ месяц) и «Завершённые аукционы» (≈ 10 дней) — дальше robots.txt не пускает
# Правила те же, что для новых лотов: разделы площадок, минимальная цена по разделу, выключенные площадки.
# За прогон — не больше BACK_CAP лотов с площадки и не дольше BACK_MIN минут: первый месяц загрузится
# за несколько прогонов, дальше добираются только пропущенные. Лот из архива помечен bf (время загрузки),
# даты появления у него нет — в «новые лоты» аналитики он не попадает.
# Отброшенные после проверки (дешевле порога, старше месяца, уже известны по konfiskat.by) — в data/backfill_skip.json:
# второй раз их страницы не открываем (25.09: без этого прогон тратил всё время на 400 уже известных машин konfiskat).
# Вызывается из update.rb после итогов торгов: там же определены new_lot, trim, ipm_kind, kf_kind.

BACK_DAYS = (ENV['BACK_DAYS'] || 30).to_i
BACK_CAP = (ENV['BACK_CAP'] || 350).to_i
BACK_MIN = (ENV['BACK_MIN'] || 25).to_f
BACK_SKIP = File.join(Store::DATA, 'backfill_skip.json')

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
  stop = Time.now + BACK_MIN * 60
  mx = Mutex.new
  known = ->(k) { mx.synchronize { db.key?(k) } }
  skip = File.exist?(BACK_SKIP) ? (JSON.parse(File.read(BACK_SKIP, encoding: 'UTF-8')) rescue {}) : {}
  skip.reject! { |_, (t, _)| t.to_i < since - 10 * 86_400 }
  skipped = ->(k) { mx.synchronize { skip[k] && skip[k][1] } }   # причина или nil
  drop = ->(k, why) { mx.synchronize { skip[k] = [now, why] } }
  add = lambda do |rec, d, photo|
    Store.save_details(rec['key'], trim(d['details'] || []))
    rec['photo'] = Store.save_photo(photo, rec['key'], Src::UA)
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
        Src.ipm_list(path, since: since).each do |c|
          break if left.zero? || Time.now > stop
          next if known.(c['key']) || skipped.(c['key'])
          sec = sec0 || ipm_kind(c['name'])
          html = Src.get(c['url']) or next
          all = (u = Res.ipm_all_bids_url(html)) && Src.get(u)
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
        Src::BT_DONE.each_value do |status|
          old = 0   # каталог — по дате аукциона от поздних к ранним: пять старых подряд — дальше только старше
          (1..30).each do |p|
            cards = Src.bt_page(slug, p, status) or break
            cards.each do |c|
              break if left.zero? || Time.now > stop || old >= 5
              next if known.(c['key'])
              case skipped.(c['key'])
              when 'old' then old += 1; next
              when 'min' then next
              end
              html = Src.get(c['url']) or next
              r = Res.bt_result(html) or next   # перевыставлен — это уже новые торги
              d = Src.bt_detail(html)
              when_ = r['at'] || d['torg'] || d['req_to']
              if when_.to_i < since
                old += 1
                drop.(c['key'], 'old')
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
        next drop.(c['key'], 'old') if c['closed_day'].to_i < since
        sleep 2
        html = Src.get(c['url']) or next
        r = Res.ba_result(html)
        next drop.(c['key'], 'min') unless back_min_ok?(c['sec'], r['price'] || c['price'])
        d = Src.ba_detail(html)
        add.(back_rec(c, c['sec'], d, r, 'belauction.by архив', now), d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end,
    'konfiskat.by' => lambda do |left|
      # тот же лот мы могли знать по konfiskat.by: «Лот №» совпадает с номером лота там
      arts = mx.synchronize { db.values.select { |l| l['platform'] == 'konfiskat.by' }.to_h { |l| [l['art'].to_s, l] } }
      tks = mx.synchronize { db.values.map { |l| l['tk'].to_s[%r{/(\d+)/?\z}, 1] }.compact.to_h { |a| [a, true] } }
      Src.tk_archive(since).each do |c|
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
                'closed' => req, 'why' => 'deadline', 'result' => r.merge('checked' => now, 'tries' => 1) }
        add.(rec, d, [d['photo_url'], c['thumb']])
        left -= 1
      end
    end
  }
  jobs.reject { |plat, _| PLAT_OFF.include?(plat) }.map do |plat, job|
    Thread.new do
      job.call(BACK_CAP)
    rescue StandardError => e
      STDERR.puts "архив площадки #{plat}: ошибка #{e.message}"
    end
  end.each(&:join)
  File.write(BACK_SKIP, JSON.generate(skip))
  STDERR.puts "архив площадок за #{BACK_DAYS} дн.: добавлено #{stat['архив площадок: добавлено']}" \
              "#{Time.now > stop ? ' (время прогона вышло — остальное в следующий раз)' : ''}"
end
