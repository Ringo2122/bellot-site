# encoding: utf-8
#
# Итоги торгов: за сколько ушёл лот, сколько было ставок и участников. Робот заглядывает на площадку
# после даты торгов и повторяет, пока итоги не опубликуют (update.rb, раздел «итоги торгов»).
#
# Результат — хеш:
#   st      sold (продан) | single (продан единственному участнику) | failed (не состоялись)
#           | cancelled (отменены) | pending (итогов ещё нет)
#   start   начальная цена, BYN        price  цена продажи, BYN
#   bids    ставок                     users  участников
#   at      когда закончились торги    note   пояснение площадки
#
# Где берём:
#   e-auction.by  служебный запрос страницы лота ajax_auctions.php?type=get-info&eid=… (JSON): статус, ставки
#   ipmtorgi.by, cpo.by  блок «Результаты торгов» на странице лота: цена продажи, победитель, ход торгов
#   beltorgi.by   строка статуса на странице лота: «Торги состоялись», «приобретен единственным участником»…
#   konfiskat.by  торги идут на torgikonfiskat.by — ссылка на них есть на странице лота konfiskat.by
require 'json'
require_relative 'sources'

module Res
  module_function

  FINAL = %w[sold single failed cancelled].freeze

  def text(html)
    html.to_s.gsub(/<script.*?<\/script>/m, ' ').gsub(/<style.*?<\/style>/m, ' ').gsub(/<!--.*?-->/m, ' ')
        .gsub(/<[^>]+>/, ' ').gsub(/&#160;|&nbsp;|&#032;/, ' ').gsub(/\s+/, ' ')
  end

  # ── e-auction ──
  def ea_eid(html)
    html.to_s[/name="eid" value="(\d+)"/, 1]
  end

  def ea_info(eid)
    out = IO.popen(['curl', '-sS', '-m', '30', '-A', Src::UA, '-H', 'X-Requested-With: XMLHttpRequest',
                    "#{Src::EA}/local/include/ajax_auctions.php?type=get-info&eid=#{eid}"], err: File::NULL, &:read)
    JSON.parse(out.to_s.force_encoding('UTF-8'))['result']
  rescue JSON::ParserError, NoMethodError
    nil
  end

  # онлайн-торги e-auction идут не в день окончания приёма заявок, а по отдельному расписанию
  def ea_torg(info)
    e = info && info.dig('lot_info', 'element') or return nil
    e['TIME_START_BIDDING'].to_i.positive? ? e['TIME_START_BIDDING'].to_i : nil
  end

  def ea_result(info)
    e = info && info.dig('lot_info', 'element') or return nil
    list = info.dig('lot_info', 'list') || []
    bids = list.map { |b| b['UF_BID'].to_f }
    users = e['COUNT_REQUESTS'].to_i.positive? ? e['COUNT_REQUESTS'].to_i : list.map { |b| b['UF_USER_CODE'] }.uniq.size
    st = case e['LOT_STATUS'].to_i
         when 20 then users == 1 ? 'single' : 'sold'
         when 21 then 'failed'
         when 55, 119 then 'cancelled'
         else 'pending'
         end
    price = e['MAX_BID_PRICE'].to_f.positive? ? e['MAX_BID_PRICE'].to_f : bids.max
    r = { 'st' => st, 'start' => e['START_PRICE'].to_f, 'bids' => e['COUNT_BIDS'].to_i.positive? ? e['COUNT_BIDS'].to_i : bids.size,
          'users' => users, 'at' => [e['TIME_END_BIDDING'].to_i, list.map { |b| b['UF_DATE_UNIX'].to_i }.max.to_i].max }
    r['price'] = price if %w[sold single].include?(st) && price.to_f.positive?
    r['note'] = 'победитель не оплатил лот' if e['WINNER_IS_NOT_PAY'].to_s == 'Y'
    r
  end

  # ── ИПМ-Торги и ЦПО ──
  def ipm_result(html)
    t = text(html)
    blk = t[/Результаты торгов (.{0,900}?)(?:Тип торгов|Ход торгов|Информация о лоте)/, 1] or return { 'st' => 'pending' }
    rows = t[/Ход торгов(.*?)(?:Посмотреть все ставки|Информация о лоте)/, 1].to_s
             .scan(/(\d+)\s+Пользователь с ID (\d+)\s+([\d\s.,]+?)\s*BYN/)
    price = blk[/Цена продажи:\s*([\d\s.,]+?)\s*BYN/, 1]
    users = rows.map { |r| r[1] }.uniq.size
    st = if price then users == 1 ? 'single' : 'sold'
         elsif blk =~ /Победитель:\s*Не выявлен/ then 'failed'
         else 'pending'
         end
    r = { 'st' => st, 'start' => Src.num(blk[/Начальная цена:\s*([\d\s.,]+?)\s*BYN/, 1]), 'at' => Src.ts(blk[/(\d{2}\.\d{2}\.\d{4}\s+\d{1,2}:\d{2})/, 1]),
          'bids' => rows.map { |r| r[0].to_i }.max.to_i, 'users' => users }
    r['price'] = Src.num(price) if price
    r
  end

  # ── Белреализация ──
  def bt_result(html)
    t = text(html)
    seg = t[/Допущено участников.{0,1800}/].to_s
    st = if seg =~ /Торги состоялись/ then 'sold'
         elsif seg =~ /приобретен единственным участником/i then 'single'
         elsif seg =~ /Торги не состоялись/ then 'failed'
         elsif seg =~ /Торги отменены|снят с торгов|Торги приостановлены/i then 'cancelled'
         elsif seg =~ /Прием заявок на участие/ then return nil   # перевыставлен — это уже новые торги
         else 'pending'
         end
    r = { 'st' => st, 'start' => Src.num(seg[/Начальная цена\s*([\d\s,]+?)\s*бел/, 1]) }
    if (p = seg[/Цена продажи\s*([\d\s,]+?)\s*бел/, 1])
      r['price'] = Src.num(p)
    end
    bids = seg[/Ставки участников(.*)/, 1].to_s.scan(/\(участник №/).size
    r['bids'] = bids if bids.positive?
    users = seg[/Допущено участников\s*(\d+)/, 1].to_i
    r['users'] = users if users.positive?
    at = Src.ts(seg[/Окончание торгов\s*(\d{2}\.\d{2}\.\d{4})/, 1].to_s + ' ' + seg[/Окончание торгов\s*\d{2}\.\d{2}\.\d{4}\S*\s*(\d{1,2}:\d{2})/, 1].to_s)
    r['at'] = at if at
    r['note'] = 'ожидаются повторные торги' if seg =~ /ожидаются повторные торги/
    r
  end

  # ── konfiskat.by → torgikonfiskat.by ──
  def kf_tk_url(html)
    u = html.to_s[%r{href="(https?://torgikonfiskat\.by/[a-z-]*auction/\d+/?)"}, 1]
    u && u.sub('http://', 'https://')
  end

  def tk_result(html)
    t = text(html)
    s = t[/Статус\s+(.{3,40}?)\s+Дата проведения/, 1].to_s
    bids = t.scan(/Ставка\s+([\d\s,]+?)\s*BYN/).map { |x| Src.num(x[0]) }
    users = t.scan(/Код участника\s+([A-Z0-9]{10,})/).flatten.uniq.size
    st = if s =~ /успешно/i then users == 1 ? 'single' : 'sold'
         elsif s =~ /не состоял/i then 'failed'
         elsif s =~ /отмен/i then 'cancelled'
         else 'pending'
         end
    r = { 'st' => st, 'start' => Src.num(t[/Начальная цена:\s*([\d\s,]+?)\s*руб/, 1]), 'bids' => bids.size, 'users' => users,
          'at' => Src.ts("#{t[/Дата проведения\s+(\d{2}\.\d{2}\.\d{4})/, 1]} 12:00") }
    r['price'] = bids.max if %w[sold single].include?(st) && bids.any?
    r
  end
end
