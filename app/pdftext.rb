# encoding: utf-8
# Текст из простого PDF: шрифты с таблицами ToUnicode (двухбайтовые коды), сжатие FlateDecode.
# Нужен для извещений konfiskat.by: срок заявок и задаток там только в PDF. Внешних программ не требует.
require 'zlib'
module PdfText
  module_function

  def objects(d)
    d.scan(/(\d+) 0 obj(.*?)endobj/m).each_with_object({}) { |(n, body), h| h[n.to_i] = body }
  end

  def stream(body)
    s = body[/stream\r?\n(.*)\r?\nendstream/m, 1] or return nil
    body.include?('/FlateDecode') ? (Zlib::Inflate.inflate(s) rescue nil) : s
  end

  def cmap(src)
    m = {}
    src.scan(/beginbfchar(.*?)endbfchar/m).flatten.each do |blk|
      blk.scan(/<(\h+)>\s*<(\h+)>/) { |a, b| m[a.hex] = [b].pack('H*').force_encoding('UTF-16BE').encode('UTF-8') rescue nil }
    end
    src.scan(/beginbfrange(.*?)endbfrange/m).flatten.each do |blk|
      blk.scan(/<(\h+)>\s*<(\h+)>\s*<(\h+)>/) do |a, b, c|
        (a.hex..b.hex).each_with_index { |code, i| m[code] = [c.hex + i].pack('U') }
      end
    end
    m
  end

  def unescape(s)
    s.gsub(/\\([nrtbf()\\]|\d{1,3})/) { |x| e = $1; e =~ /\d/ ? e.to_i(8).chr : { 'n' => "\n", 'r' => "\r", 't' => "\t", 'b' => "\b", 'f' => "\f" }[e] || e }
  end

  def text(path)
    d = File.binread(path)
    objs = objects(d)
    fonts = {}   # имя ресурса (/F1) → таблица
    objs.each_value do |body|
      body.scan(%r{/(F\d+)\s+(\d+)\s+0\s+R}) do |name, ref|
        fo = objs[ref.to_i] or next
        tu = fo[%r{/ToUnicode\s+(\d+)\s+0\s+R}, 1] or next
        src = stream(objs[tu.to_i].to_s) or next
        fonts[name] ||= cmap(src)
      end
    end
    out = +''
    objs.each_value do |body|
      c = stream(body) or next
      next unless c.include?('BT')
      font = nil
      c.scan(%r{/(F\d+)\s+[\d.]+\s+Tf|\[(.*?)\]\s*TJ|\((.*?)\)\s*Tj|(T\*|Td|TD|ET)}m) do |f, arr, single, op|
        if f then font = fonts[f]
        elsif op then out << (op == 'ET' ? "\n" : ' ')
        else
          parts = arr ? arr.scan(/\((.*?)(?<!\\)\)/m).flatten : [single]
          parts.each do |p|
            b = unescape(p).b
            out << (0...b.size / 2).map { |i| (font || {})[b.getbyte(2 * i) * 256 + b.getbyte(2 * i + 1)] || '' }.join
          end
        end
      end
    end
    out.gsub(/[ \t]+/, ' ')
  end
end
