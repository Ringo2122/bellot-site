# encoding: utf-8
#
# Данные «Аналитики» (кабинет и админка) — зашифрованным файлом на сайте, а не из базы (15.10).
# Раньше каждое открытие аналитики скачивало из Supabase все лоты и итоги (~30 МБ), а каждая сборка —
# всю таблицу итогов (~12 МБ): бесплатный лимит базы — 5 ГБ в месяц, с пользователями его хватило бы на дни.
#
# Как устроено:
#   сборка  кладёт st/<случайное имя>.bin: JSON (лоты и итоги столбцами) → gzip → AES-256 + подпись, новым ключом;
#           имя и ключ — в tmp/stats_file.json, sync.rb после выкладки сайта записывает их в таблицу stats_file
#   браузер rpc stats_file() отдаёт имя и ключ только вошедшему в кабинет или в админку (две последние сборки);
#           файл — с сайта, расшифровка и распаковка — в браузере (stats.js, BLStats.load)
#   прежний файл сборка переносит в новую версию сайта: тот, кто получил старое имя за минуту до выкладки, его найдёт
#
# Копия итогов торгов: прошлый файл — заодно копия таблицы sales. Сборка берёт итоги из него, а всю таблицу из базы
# перекачивает, только если копии нет, она не расшифровалась, число строк в базе с ней не сходится или ей больше 7 дней.
require 'json'
require 'zlib'
require 'base64'
require 'openssl'
require 'securerandom'
require 'net/http'
require 'uri'

module StatsFile
  module_function

  SITE = ENV['STATS_SITE'] || 'https://monitorg.by'   # STATS_SITE — для проверки на локальной копии
  VER = 1
  LOT_COLS = %w[id name url platform section price price0 req_to first_seen closed why status published hidden_why region
                location market reasons photo area_num debtor result city].freeze   # = BLStats.FIELDS в stats.js
  # city — город/район (regions.rb), rnd — круг торгов объекта, s1 — начальная цена 1-го круга (similar.rb)
  SALE_COLS = %w[key at id platform section region location name debtor area_num url st start price bids users city rnd s1].freeze
  FULL_EVERY = 7 * 86_400   # копию итогов сверяем с базой целиком раз в неделю

  def cols(rows, cols) { 'c' => cols, 'r' => rows.map { |x| cols.map { |k| x[k] } } } end
  def rows(t) t['r'].map { |r| t['c'].zip(r).to_h } end

  # → [байты файла, ключ base64]. AES-256-CBC + HMAC-SHA256 (шифр, потом подпись): ключ — 64 байта, первые 32 — шифр,
  # вторые — подпись; файл = IV (16) + шифротекст + подпись (32). Подпись проверяется до расшифровки: испорченный или
  # подменённый файл не откроется. (GCM не взяли: в Ruby на Mac для проверки на локальной копии он не работает.)
  def seal(obj)
    key = SecureRandom.random_bytes(64)
    iv = SecureRandom.random_bytes(16)
    c = OpenSSL::Cipher.new('aes-256-cbc').encrypt
    c.key = key[0, 32]
    c.iv = iv
    body = iv + c.update(Zlib.gzip(JSON.generate(obj), level: 9)) + c.final
    [body + OpenSSL::HMAC.digest('SHA256', key[32, 32], body), Base64.strict_encode64(key)]
  end

  def open(bytes, key64)
    bytes = bytes.b
    key = Base64.strict_decode64(key64)
    raise 'файл слишком короткий' if bytes.size < 64
    body = bytes[0...-32]
    raise 'подпись не сходится' unless OpenSSL::HMAC.digest('SHA256', key[32, 32], body) == bytes[-32..]
    c = OpenSSL::Cipher.new('aes-256-cbc').decrypt
    c.key = key[0, 32]
    c.iv = body[0, 16]
    JSON.parse(Zlib.gunzip(c.update(body[16..]) + c.final).force_encoding('UTF-8'))
  end

  def download(name)
    u = URI("#{SITE}/st/#{name}.bin")
    res = Net::HTTP.start(u.host, u.port, use_ssl: u.scheme == 'https', open_timeout: 15, read_timeout: 60) { |h| h.get(u.request_uri) }
    raise "сайт ответил #{res.code}" unless res.code.to_i == 200
    res.body
  end

  # прошлый файл с сайта: {'bytes', 'name', 'data'} или nil — тогда всё как раньше, из базы
  def previous(ptr)
    return nil unless ptr && ptr['name'] && ptr['key']
    bytes = download(ptr['name'])
    data = open(bytes, ptr['key'])
    raise 'не та версия файла' unless data['v'] == VER && data['sales'] && data['lots']
    { 'bytes' => bytes, 'name' => ptr['name'], 'data' => data }
  rescue StandardError => e
    warn "аналитика: прошлый файл не взят (#{e.message}) — итоги перекачаем из базы"
    nil
  end
end
