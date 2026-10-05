#!/usr/bin/env ruby
# encoding: utf-8
#
# Заливка кода в Ringo2122/bellot-site одним коммитом через GitHub API (git на машине нет).
#   MSG="…" ruby tools/push.rb   код: app/ (с app/noph/, app/img/), .github/workflows/, tools/, supabase/, README.md — data/ не трогает.
#   Файл, удалённый здесь из этих папок, удаляется и в репозитории.
# Память (data/) ведёт робот. Заливать её отсюда поверх — значит стереть то, что он собрал.
require 'json'
require 'base64'
Encoding.default_external = Encoding::UTF_8

GH   = File.expand_path('~/bin/gh')
REPO = 'Ringo2122/bellot-site'
ROOT = File.expand_path('..', __dir__)

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

files = Dir.chdir(ROOT) { Dir['app/*', 'app/noph/*', 'app/img/*', '.github/workflows/*', 'tools/*', 'supabase/*', 'README.md'].select { |f| File.file?(f) } }

tree = files.map do |f|
  b = api('POST', "repos/#{REPO}/git/blobs",
          'content' => Base64.strict_encode64(File.binread(File.join(ROOT, f))), 'encoding' => 'base64')
  { 'path' => f, 'mode' => '100644', 'type' => 'blob', 'sha' => b['sha'] }
end
# удалённое здесь — удалить и в репозитории (только в папках кода)
stale = remote.select { |p| p =~ %r{\A(app|tools|supabase|\.github/workflows)/} || p == 'README.md' } - files
tree += stale.map { |p| { 'path' => p, 'mode' => '100644', 'type' => 'blob', 'sha' => nil } }

t = api('POST', "repos/#{REPO}/git/trees", 'base_tree' => base, 'tree' => tree)
msg = (ENV['MSG'] || 'код сайта').dup.force_encoding('UTF-8')
c = api('POST', "repos/#{REPO}/git/commits", 'message' => msg, 'tree' => t['sha'], 'parents' => [parent])
api('PATCH', "repos/#{REPO}/git/refs/heads/main", 'sha' => c['sha'])
puts "коммит #{c['sha'][0, 7]}: файлов #{files.size}, удалено старых #{stale.size}"
