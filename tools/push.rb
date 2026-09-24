#!/usr/bin/env ruby
# encoding: utf-8
#
# Заливка кода в Ringo2122/bellot-site одним коммитом через GitHub API (git на машине нет).
#   ruby tools/push.rb          код: app/, .github/, tools/, README.md — data/ не трогает
#   ruby tools/push.rb --seed   ещё и первая память: data/ упаковывается в data/seed.tgz,
#                               робот распакует её при первом прогоне. Только если data/ в репозитории нет.
# Память (data/) ведёт робот. Заливать её отсюда поверх — значит стереть то, что он собрал.
require 'json'
require 'base64'
Encoding.default_external = Encoding::UTF_8

GH   = File.expand_path('~/bin/gh')
REPO = 'Ringo2122/bellot-site'
ROOT = File.expand_path('..', __dir__)
SEED = ARGV.include?('--seed')

def gh(*args, input: nil)
  out = IO.popen([GH, *args], 'r+', err: %i[child out]) do |io|
    io.write(input) if input
    io.close_write
    io.read
  end
  [out.to_s, $?.success?]
end

def api(method, path, body = nil)
  out, ok = gh('api', '--method', method, path, *(body ? ['--input', '-'] : []), input: body && JSON.generate(body))
  abort("#{method} #{path}: #{out[0, 300]}") unless ok
  JSON.parse(out)
end

ref = api('GET', "repos/#{REPO}/git/ref/heads/main")
parent = ref['object']['sha']
base = api('GET', "repos/#{REPO}/git/commits/#{parent}")['tree']['sha']
remote = api('GET', "repos/#{REPO}/git/trees/#{base}?recursive=1")['tree'].map { |t| t['path'] }

files = Dir.chdir(ROOT) { Dir['app/*', '.github/workflows/*', 'tools/*', 'supabase/*', 'README.md'].select { |f| File.file?(f) } }
if SEED
  abort('в репозитории уже есть память робота — seed не нужен и опасен') if remote.include?('data/lots.json')
  Dir.chdir(File.join(ROOT, 'data')) do
    system('tar', 'czf', 'seed.tgz', 'lots.json', 'det', 'ph') or abort('не упаковалась память')
  end
  files << 'data/seed.tgz'
end

tree = files.map do |f|
  b = api('POST', "repos/#{REPO}/git/blobs",
          'content' => Base64.strict_encode64(File.binread(File.join(ROOT, f))), 'encoding' => 'base64')
  { 'path' => f, 'mode' => '100644', 'type' => 'blob', 'sha' => b['sha'] }
end
# прежняя статичная выкладка (index.html и пачки в корне) больше не нужна — сайт собирает робот
stale = remote.select { |p| p =~ %r{\A(index\.html|\.nojekyll|ph/p\d+\.js)\z} }
tree += stale.map { |p| { 'path' => p, 'mode' => '100644', 'type' => 'blob', 'sha' => nil } }

t = api('POST', "repos/#{REPO}/git/trees", 'base_tree' => base, 'tree' => tree)
msg = SEED ? 'код сайта и первая память' : 'код сайта'
c = api('POST', "repos/#{REPO}/git/commits", 'message' => msg, 'tree' => t['sha'], 'parents' => [parent])
api('PATCH', "repos/#{REPO}/git/refs/heads/main", 'sha' => c['sha'])
File.delete(File.join(ROOT, 'data', 'seed.tgz')) if SEED
puts "коммит #{c['sha'][0, 7]}: файлов #{files.size}, удалено старых #{stale.size}"
