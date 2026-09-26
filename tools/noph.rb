#!/usr/bin/env ruby
# encoding: utf-8
#
# Заглушки «нет фото» для лотов без фотографий — по разделам, объёмные значки (SVG, 4:3 как фото в карточках).
#   ruby tools/noph.rb   → app/noph/<раздел>.svg (сборка копирует их в _site/noph/)
# Цвета — как у разделов на сайте. Тёмная тема — через prefers-color-scheme внутри SVG.
require 'fileutils'

OUT = File.expand_path('../app/noph', __dir__)
FileUtils.mkdir_p(OUT)

def frame(id, bg1, bg2, body, dark1 = '#1a2129', dark2 = '#141a21')
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300" width="400" height="300">
    <style>
      .bg1{stop-color:#{bg1}} .bg2{stop-color:#{bg2}} .cap{fill:#6b7a8c}
      @media (prefers-color-scheme: dark){ .bg1{stop-color:#{dark1}} .bg2{stop-color:#{dark2}} .cap{fill:#8e9aa8} }
    </style>
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="bg1"/><stop offset="1" class="bg2"/></linearGradient>
      <radialGradient id="sh" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#0b1a2c" stop-opacity=".32"/><stop offset=".6" stop-color="#0b1a2c" stop-opacity=".12"/><stop offset="1" stop-color="#0b1a2c" stop-opacity="0"/></radialGradient>
      <linearGradient id="gl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".75"/><stop offset=".5" stop-color="#fff" stop-opacity=".15"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
      <linearGradient id="glass" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#d6ecff"/><stop offset="1" stop-color="#7fb2e0"/></linearGradient>
      <radialGradient id="tire" cx=".42" cy=".38" r=".7"><stop offset="0" stop-color="#4a525c"/><stop offset=".7" stop-color="#262b31"/><stop offset="1" stop-color="#15181c"/></radialGradient>
      <radialGradient id="rim" cx=".38" cy=".32" r=".75"><stop offset="0" stop-color="#ffffff"/><stop offset=".55" stop-color="#c9d0d8"/><stop offset="1" stop-color="#7d8894"/></radialGradient>
      #{body[:defs]}
    </defs>
    <rect width="400" height="300" fill="url(#bg)"/>
    #{body[:svg]}
    <text x="200" y="274" text-anchor="middle" font-family="-apple-system,'Segoe UI',Roboto,Arial,sans-serif" font-size="17" font-weight="600" letter-spacing=".6" class="cap">нет фото</text>
    </svg>
  SVG
end

def wheel(cx, cy, r)
  %(<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="url(#tire)"/>) +
    %(<circle cx="#{cx}" cy="#{cy}" r="#{(r * 0.56).round(1)}" fill="url(#rim)"/>) +
    %(<circle cx="#{cx}" cy="#{cy}" r="#{(r * 0.2).round(1)}" fill="#8a949f"/>) +
    %(<circle cx="#{cx}" cy="#{cy}" r="#{(r * 0.56).round(1)}" fill="none" stroke="#5d6772" stroke-width="1.5" stroke-opacity=".5"/>)
end

# ── недвижимость: изометрический дом ──
# ось вправо-вверх r=(0.866,-0.5), влево-вверх l=(-0.866,-0.5); угол дома у земли O=(185,210)
def iso(u, s, v)
  [(185 + 0.866 * u - 0.866 * s).round(1), (210 - 0.5 * u - 0.5 * s - v).round(1)]
end

def poly(pts, attrs)
  %(<polygon points="#{pts.map { |x, y| "#{x},#{y}" }.join(' ')}" #{attrs}/>)
end

house = {
  defs: <<~D,
    <linearGradient id="wf" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fffdf8"/><stop offset="1" stop-color="#eee3cf"/></linearGradient>
    <linearGradient id="ws" x1="1" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e3d6bd"/><stop offset="1" stop-color="#c9b894"/></linearGradient>
    <linearGradient id="rf" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#5aa2f0"/><stop offset="1" stop-color="#1d5aa6"/></linearGradient>
    <linearGradient id="dr" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#9b6a3a"/><stop offset="1" stop-color="#6a4220"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="196" cy="214" rx="118" ry="17" fill="url(#sh)"/>),
    poly([iso(0, 0, 0), iso(0, 70, 0), iso(0, 70, 60), iso(0, 35, 105), iso(0, 0, 60)], 'fill="url(#ws)"'),          # торец с фронтоном
    poly([iso(0, 0, 0), iso(100, 0, 0), iso(100, 0, 60), iso(0, 0, 60)], 'fill="url(#wf)"'),                           # фасад
    poly([iso(0, 0, 0), iso(100, 0, 0), iso(100, 0, 6), iso(0, 0, 6)], 'fill="#d9ccb2"'),                                # цоколь
    poly([iso(-4, -4, 57), iso(104, -4, 57), iso(104, 35, 107), iso(-4, 35, 107)], 'fill="url(#rf)"'),                 # скат крыши
    poly([iso(-4, -4, 57), iso(104, -4, 57), iso(104, -4, 51), iso(-4, -4, 51)], 'fill="#164a8c"'),                     # край крыши
    poly([iso(-4, -4, 57), iso(-4, 35, 107), iso(-4, 74, 57), iso(-4, 74, 51), iso(-4, 35, 101), iso(-4, -4, 51)], 'fill="#12407a"'), # торец крыши
    poly([iso(8, -4, 58), iso(96, -4, 58), iso(96, 12, 78), iso(8, 12, 78)], 'fill="url(#gl)" opacity=".45"'),         # блик на крыше
    poly([iso(60, 0, 0), iso(78, 0, 0), iso(78, 0, 40), iso(60, 0, 40)], 'fill="url(#dr)"'),                            # дверь
    %(<circle cx="#{iso(74, 0, 20)[0]}" cy="#{iso(74, 0, 20)[1]}" r="1.8" fill="#f3d27a"/>),
    poly([iso(14, 0, 18), iso(42, 0, 18), iso(42, 0, 44), iso(14, 0, 44)], 'fill="#fff"'),
    poly([iso(16, 0, 20), iso(40, 0, 20), iso(40, 0, 42), iso(16, 0, 42)], 'fill="url(#glass)"'),
    poly([iso(16, 0, 34), iso(26, 0, 42), iso(20, 0, 42), iso(16, 0, 38)], 'fill="#fff" opacity=".7"'),
    poly([iso(0, 18, 18), iso(0, 48, 18), iso(0, 48, 44), iso(0, 18, 44)], 'fill="#f4ecdc"'),
    poly([iso(0, 20, 20), iso(0, 46, 20), iso(0, 46, 42), iso(0, 20, 42)], 'fill="#8fbbe3"'),
    poly([iso(0, 26, 58), iso(0, 44, 58), iso(0, 44, 76), iso(0, 26, 76)], 'fill="#8fbbe3" opacity=".9"')
  ].join("\n")
}

# ── легковые: глянцевый автомобиль ──
car = {
  defs: <<~D,
    <linearGradient id="cb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4fd1c5"/><stop offset=".45" stop-color="#17a397"/><stop offset="1" stop-color="#0b605a"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="203" cy="216" rx="128" ry="15" fill="url(#sh)"/>),
    %(<path d="M96 196 C86 196 84 186 86 174 L90 158 C92 148 100 143 112 142 L140 139 C152 118 168 104 192 102 L240 102 C256 102 268 110 280 124 L292 138 C308 140 318 148 320 160 L322 180 C322 192 316 196 304 196 Z" fill="url(#cb)"/>),
    %(<path d="M151 138 C161 120 174 110 193 109 L238 109 C251 109 260 116 270 130 L274 136 Z" fill="url(#glass)"/>),
    %(<path d="M213 109 L211 137" stroke="#0e6f67" stroke-width="5"/>),
    %(<path d="M151 138 L274 136 L276 142 L148 144 Z" fill="#0f7f75"/>),
    %(<path d="M100 150 C130 144 250 140 312 150 L313 156 C250 148 130 151 99 158 Z" fill="#fff" opacity=".38"/>),
    %(<path d="M88 182 L322 182 L322 188 C322 194 316 196 304 196 L96 196 C88 196 86 190 88 182 Z" fill="#0a4f4a"/>),
    %(<path d="M211 145 L212 180" stroke="#0e6f67" stroke-width="1.6" opacity=".7"/>),
    %(<rect x="222" y="152" width="14" height="3.5" rx="1.7" fill="#dff7f4"/>),
    %(<rect x="164" y="152" width="14" height="3.5" rx="1.7" fill="#dff7f4"/>),
    %(<path d="M306 150 C314 152 318 156 319 162 L306 162 Z" fill="#fff4c2"/>),
    %(<path d="M88 156 L96 154 L95 166 L87 167 Z" fill="#e0483f"/>),
    %(<path d="M118 196 A32 32 0 0 1 182 196 Z" fill="#083f3b"/>),
    %(<path d="M232 196 A32 32 0 0 1 296 196 Z" fill="#083f3b"/>),
    wheel(150, 196, 27), wheel(264, 196, 27)
  ].join("\n")
}

# ── грузовые и автобусы: грузовик с кузовом-фургоном ──
truck = {
  defs: <<~D,
    <linearGradient id="tb" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a48ae6"/><stop offset="1" stop-color="#5a3fa3"/></linearGradient>
    <linearGradient id="tt" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#c9b8f5"/><stop offset="1" stop-color="#b09ce9"/></linearGradient>
    <linearGradient id="tc" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f7f8fb"/><stop offset="1" stop-color="#c3c9d4"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="204" cy="216" rx="136" ry="15" fill="url(#sh)"/>),
    %(<path d="M84 86 L96 76 L248 76 L236 86 Z" fill="url(#tt)"/>),
    %(<path d="M236 86 L248 76 L248 176 L236 186 Z" fill="#4a3290"/>),
    %(<rect x="84" y="86" width="152" height="100" rx="4" fill="url(#tb)"/>),
    %(<path d="M88 90 L232 90 L232 104 L88 116 Z" fill="#fff" opacity=".22"/>),
    [118, 152, 186, 220].map { |x| %(<path d="M#{x} 92 L#{x} 180" stroke="#4d3596" stroke-width="1.4" opacity=".55"/>) }.join,
    %(<path d="M244 116 L290 116 C300 116 306 122 310 132 L318 156 L318 188 L244 188 Z" fill="url(#tc)"/>),
    %(<path d="M252 124 L288 124 C294 124 298 128 300 134 L306 152 L252 152 Z" fill="url(#glass)"/>),
    %(<path d="M252 124 L270 124 L252 142 Z" fill="#fff" opacity=".6"/>),
    %(<rect x="244" y="170" width="74" height="18" fill="#8f98a6"/>),
    %(<rect x="306" y="162" width="12" height="7" rx="2" fill="#fff4c2"/>),
    %(<rect x="80" y="184" width="240" height="8" rx="3" fill="#39414b"/>),
    wheel(124, 196, 23), wheel(174, 196, 23), wheel(286, 196, 23)
  ].join("\n")
}

# ── спецтехника: экскаватор ──
exc = {
  defs: <<~D,
    <linearGradient id="eo" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffc15a"/><stop offset=".55" stop-color="#f39a2b"/><stop offset="1" stop-color="#c2651a"/></linearGradient>
    <linearGradient id="ea" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#d97414"/></linearGradient>
    <linearGradient id="et" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4b535d"/><stop offset="1" stop-color="#1e2227"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="206" cy="216" rx="124" ry="15" fill="url(#sh)"/>),
    %(<rect x="146" y="176" width="170" height="36" rx="18" fill="url(#et)"/>),
    %(<rect x="152" y="182" width="158" height="24" rx="12" fill="#2d333a"/>),
    [170, 200, 231, 262, 292].map { |x| %(<circle cx="#{x}" cy="194" r="9" fill="url(#rim)"/>) }.join,
    %(<rect x="176" y="164" width="120" height="14" rx="4" fill="#2f353c"/>),
    %(<path d="M166 124 L300 124 C306 124 310 128 310 134 L310 166 L166 166 Z" fill="url(#eo)"/>),
    %(<path d="M170 128 L306 128 L306 136 L170 140 Z" fill="#fff" opacity=".3"/>),
    %(<path d="M232 76 L276 76 C284 76 290 82 290 90 L290 126 L232 126 Z" fill="url(#eo)"/>),
    %(<path d="M240 84 L276 84 C280 84 282 86 282 90 L282 120 L240 120 Z" fill="url(#glass)"/>),
    %(<path d="M240 84 L258 84 L240 104 Z" fill="#fff" opacity=".6"/>),
    %(<path d="M186 132 L150 70 L130 64 L118 74 L166 146 Z" fill="url(#ea)"/>),
    %(<path d="M150 70 L130 64 L118 74 L126 80 Z" fill="#fff" opacity=".3"/>),
    %(<path d="M124 70 L100 150 L114 154 L140 76 Z" fill="url(#ea)"/>),
    %(<path d="M92 146 C84 160 88 178 104 184 L128 180 L118 150 Z" fill="#5c646e"/>),
    %(<path d="M94 172 L104 184 L128 180 L124 170 Z" fill="#3a4148"/>),
    %(<circle cx="130" cy="70" r="6" fill="#3a4148"/>), %(<circle cx="108" cy="150" r="5" fill="#3a4148"/>), %(<circle cx="178" cy="138" r="6" fill="#3a4148"/>)
  ].join("\n")
}

# ── оборудование: объёмная шестерня ──
def gear(cx, cy, ro, ri, n)
  pts = []
  n.times do |i|
    a = 2 * Math::PI * i / n
    s = Math::PI / n
    [[-0.55, ri], [-0.32, ro], [0.32, ro], [0.55, ri]].each do |k, r|
      pts << [(cx + r * Math.cos(a + k * s)).round(1), (cy + r * Math.sin(a + k * s)).round(1)]
    end
  end
  'M' + pts.map { |x, y| "#{x} #{y}" }.join(' L') + ' Z'
end

cog = {
  defs: <<~D,
    <linearGradient id="gm" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e9eef4"/><stop offset=".5" stop-color="#a9b6c6"/><stop offset="1" stop-color="#6c7b8f"/></linearGradient>
    <linearGradient id="gd" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6b7a8e"/><stop offset="1" stop-color="#3f4a58"/></linearGradient>
    <linearGradient id="gm2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffd27a"/><stop offset="1" stop-color="#d98e1c"/></linearGradient>
    <linearGradient id="gd2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#b8741a"/><stop offset="1" stop-color="#7e4a0c"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="206" cy="216" rx="112" ry="15" fill="url(#sh)"/>),
    %(<path d="#{gear(178, 134, 70, 56, 12)}" fill="url(#gd)" transform="translate(9 9)"/>),
    %(<path d="#{gear(178, 134, 70, 56, 12)}" fill="url(#gm)"/>),
    %(<circle cx="178" cy="134" r="24" fill="url(#gd)"/>), %(<circle cx="178" cy="134" r="17" fill="#e7ecf2"/>),
    %(<path d="#{gear(178, 134, 70, 56, 12)}" fill="url(#gl)" opacity=".35"/>),
    %(<path d="#{gear(270, 172, 40, 31, 9)}" fill="url(#gd2)" transform="translate(7 7)"/>),
    %(<path d="#{gear(270, 172, 40, 31, 9)}" fill="url(#gm2)"/>),
    %(<circle cx="270" cy="172" r="12" fill="url(#gd2)"/>), %(<circle cx="270" cy="172" r="7" fill="#fbe7c2"/>)
  ].join("\n")
}

# ── прочее: коробка ──
box = {
  defs: <<~D,
    <linearGradient id="bt" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f0d3a4"/><stop offset="1" stop-color="#dcb57a"/></linearGradient>
    <linearGradient id="bf" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e2b877"/><stop offset="1" stop-color="#c7964f"/></linearGradient>
    <linearGradient id="bs" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#c18d45"/><stop offset="1" stop-color="#a0722f"/></linearGradient>
  D
  svg: [
    %(<ellipse cx="200" cy="214" rx="104" ry="15" fill="url(#sh)"/>),
    poly([iso(0, 0, 0), iso(0, 80, 0), iso(0, 80, 90), iso(0, 0, 90)], 'fill="url(#bs)"'),
    poly([iso(0, 0, 0), iso(80, 0, 0), iso(80, 0, 90), iso(0, 0, 90)], 'fill="url(#bf)"'),
    poly([iso(0, 0, 90), iso(80, 0, 90), iso(80, 80, 90), iso(0, 80, 90)], 'fill="url(#bt)"'),
    poly([iso(34, 0, 90), iso(46, 0, 90), iso(46, 80, 90), iso(34, 80, 90)], 'fill="#f6e7c8"'),
    poly([iso(34, 0, 90), iso(46, 0, 90), iso(46, 0, 60), iso(34, 0, 60)], 'fill="#f1dcb2"')
  ].join("\n")
}

{ 'nedvizhimost' => [house, '#eaf2fb', '#d6e5f5'], 'avto' => [car, '#e6f5f3', '#cfe9e5'], 'gruz' => [truck, '#f0ecfa', '#dfd6f3'],
  'spec' => [exc, '#fdf2e6', '#f6dfc3'], 'oborud' => [cog, '#eef1f5', '#dbe1e9'], 'other' => [box, '#f4efe6', '#e6dccb'] }.each do |k, (b, c1, c2)|
  File.write(File.join(OUT, "#{k}.svg"), frame(k, c1, c2, b))
end
puts "заглушки: #{Dir[File.join(OUT, '*.svg')].map { |f| File.basename(f) }.sort.join(', ')}"
