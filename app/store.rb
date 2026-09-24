# encoding: utf-8
#
# Память сайта. Живёт в репозитории, её дописывает каждый прогон обновления.
#   data/lots.json     короткие записи всех лотов — активных и архивных, по строке на лот
#   data/det/<key>.json подробности лота (секции «ключ — значение»), пишутся один раз
#   data/ph/<key>.jpg   фото, 400 px
# Строка на лот — чтобы в истории репозитория было видно, что изменилось за прогон.
require 'json'
require 'fileutils'

module Store
  ROOT = File.expand_path('..', __dir__)
  DATA = File.join(ROOT, 'data')
  LOTS = File.join(DATA, 'lots.json')
  DET  = File.join(DATA, 'det')
  PH   = File.join(DATA, 'ph')
  SEED = File.join(DATA, 'seed.tgz')   # первая заливка одним файлом: GitHub API не любит тысячи мелких
  W    = 400
  Q    = 48

  module_function

  def load
    FileUtils.mkdir_p([DET, PH])
    if !File.exist?(LOTS) && File.exist?(SEED)
      system('tar', 'xzf', SEED, '-C', DATA) or abort('не распаковался seed.tgz')
      File.delete(SEED)
      STDERR.puts "память распакована из seed.tgz"
    end
    File.exist?(LOTS) ? JSON.parse(File.read(LOTS, encoding: 'UTF-8')) : []
  end

  def save(lots)
    body = lots.sort_by { |l| l['key'] }.map { |l| JSON.generate(l) }.join(",\n")
    File.write(LOTS, "[\n#{body}\n]\n")
  end

  def det_path(key)
    File.join(DET, "#{key}.json")
  end

  def ph_path(key)
    File.join(PH, "#{key}.jpg")
  end

  def details(key)
    f = det_path(key)
    File.exist?(f) ? (JSON.parse(File.read(f, encoding: 'UTF-8')) rescue []) : []
  end

  def save_details(key, secs)
    File.write(det_path(key), JSON.generate(secs))
  end

  # На Mac есть sips, на сервере GitHub — ImageMagick. ImageMagick определяет формат по расширению,
  # а «.raw» для него — отдельный формат «сырых пикселей»: так 24.09 все новые фото молча не сохранились.
  # Поэтому формат узнаём по первым байтам файла и передаём явно: «jpg:файл».
  def sniff(path)
    head = File.binread(path, 12).to_s
    return 'jpg' if head.start_with?("\xFF\xD8".b)
    return 'png' if head.start_with?("\x89PNG".b)
    return 'gif' if head.start_with?('GIF8')
    return 'webp' if head[0, 4] == 'RIFF' && head[8, 4] == 'WEBP'
    nil
  end

  def shrink(src, dst)
    if system('which sips >/dev/null 2>&1')
      system('sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', Q.to_s, '-Z', W.to_s,
             src, '--out', dst, out: File::NULL, err: File::NULL)
    else
      fmt = sniff(src) or return false
      system('convert', "#{fmt}:#{src}[0]", '-auto-orient', '-resize', "#{W}x#{W}>", '-strip',
             '-quality', Q.to_s, dst, out: File::NULL, err: File::NULL)
    end
    File.exist?(dst) && File.size(dst) > 700
  end

  def save_photo(urls, key, ua)
    dst = ph_path(key)
    return true if File.exist?(dst)
    raw = dst + '.raw'
    urls.compact.uniq.each do |u|
      system('curl', '-sS', '-L', '-m', '40', '-A', ua, '-o', raw, u, out: File::NULL, err: File::NULL)
      next unless File.exist?(raw) && File.size(raw) > 1000
      ok = shrink(raw, dst)
      File.delete(raw) if File.exist?(raw)
      return true if ok
    end
    File.delete(raw) if File.exist?(raw)
    false
  end
end
