# encoding: utf-8
#
# Связь робота с базой админки (Supabase). Адрес, публичный ключ и ключ робота — из окружения:
# SB_URL, SB_KEY, SB_TOKEN (секреты GitHub). Без них робот работает как раньше, без админки.
require 'net/http'
require 'json'
require 'uri'

module Sb
  module_function

  def on?
    %w[SB_URL SB_KEY SB_TOKEN].all? { |k| !ENV[k].to_s.empty? }
  end

  def req(meth, path, body = nil, prefer = nil)
    u = URI("#{ENV['SB_URL']}/rest/v1/#{path}")
    r = Net::HTTP.const_get(meth.capitalize).new(u)
    r['apikey'] = ENV['SB_KEY']
    r['x-admin-token'] = ENV['SB_TOKEN']
    r['Content-Type'] = 'application/json'
    r['Accept-Encoding'] = 'identity'   # со сжатием Ruby не распаковывает ответ, если в нём есть Content-Range
    r['Prefer'] = prefer if prefer
    r.body = JSON.generate(body) if body
    res = nil
    3.times do |i|
      res = Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 15, read_timeout: 90) { |h| h.request(r) }
      break if res.code.to_i < 500
      sleep 3 * (i + 1)
    end
    raise "Supabase #{meth.upcase} #{path[0, 60]} → #{res.code}: #{res.body.to_s[0, 300]}" unless res.code.to_i < 300
    res.body.to_s.empty? ? nil : JSON.parse(res.body)
  end

  def get(path)
    req('get', path)
  end

  # все строки таблицы: сервер отдаёт не больше 1000 за раз
  def all(table, select = '*')
    out = []
    loop do
      part = get("#{table}?select=#{select}&order=#{table == 'dup_rules' ? 'a' : 'key'}&limit=1000&offset=#{out.size}")
      out.concat(part)
      break if part.size < 1000
    end
    out
  end

  def settings
    @settings ||= get('settings?select=k,v').map { |r| [r['k'], r['v']] }.to_h
  end

  def upsert(table, rows, conflict = 'key')
    rows.each_slice(500) { |s| req('post', "#{table}?on_conflict=#{conflict}", s, 'resolution=merge-duplicates,return=minimal') }
  end

  def insert(table, row)
    req('post', table, row, 'return=representation').first
  end

  def patch(table, filter, row)
    req('patch', "#{table}?#{filter}", row, 'return=minimal')
  end

  def delete(table, filter)
    req('delete', "#{table}?#{filter}", nil, 'return=minimal')
  end
end
