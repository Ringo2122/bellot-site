/* БелЛот — аналитика рынка. Общая для админки и личного кабинета.
   Считается в браузере по копии каталога (таблица lots) и снимкам дня (daily).
   Рынок — активные лоты всех площадок без дублей и без скрытых админом.

   BLStats.render(el, { lots, daily, leads, bots, f, blocks, href, site })
     f — фильтры { per, sec, plat, reg, kind }: период (7/30/90/all), раздел, площадка, область, тип объекта («раздел|тип»)
     blocks — какие блоки показать (id из BLStats.BLOCKS); по умолчанию все
     href(f) — ссылка на аналитику с такими фильтрами
     site — путь к сайту для ссылок на лоты ('../' из админки, '' с сайта)
     leads, bots — только для админки (блок «Заявки и бот»)
     sales — итоги завершённых торгов из постоянной таблицы sales (блок «Продажи на торгах») */
(function(){
  const BLOCKS = [
    ['kpi', 'Главные цифры'], ['fresh', 'Новые лоты по дням'], ['size', 'Размер рынка по дням'],
    ['plat', 'Площадки'], ['sec', 'Разделы'], ['reg', 'Регионы'], ['prices', 'Стартовые цены'],
    ['disc', 'Скидка к рынку'], ['soon', 'Закрытие приёма заявок, 14 дней'], ['sqm', 'Недвижимость: цена м²'],
    ['sellers', 'Крупнейшие продавцы'], ['topdisc', 'Самая большая скидка'], ['drops', 'Снижение цены'], ['results', 'Итоги торгов'], ['sales', 'Продажи на торгах: регионы, объекты, цены'],
    ['quality', 'Качество данных площадок'], ['demand', 'Заявки и Telegram-бот'], ['csv', 'Выгрузка в Excel']
  ];
  const ADMIN_ONLY = ['quality', 'demand'];   // в кабинет не отдаются, даже если отмечены
  const SECS = [['nedvizhimost','Недвижимость'],['avto','Легковые авто'],['gruz','Грузовые и автобусы'],['spec','Спецтехника'],['oborud','Оборудование']];
  const SEC_RU = Object.fromEntries(SECS);
  const PLATS = ['e-auction.by','ipmtorgi.by','beltorgi.by','konfiskat.by'];
  const COL = { nedvizhimost:'#12508f', avto:'#d9761f', gruz:'#1d7a4d', spec:'#7a4fa3', oborud:'#7b8794' };
  const REG = ['г. Минск','Минская область','Брестская область','Витебская область','Гомельская область','Гродненская область','Могилевская область'];

  // Тип объекта по названию лота — для «какие объекты продаются». У легковых — марка.
  // \b в JS не работает с кириллицей — границы слова через (?:^|[^a-zа-я])
  const W = w => `(?:^|[^a-zа-я0-9])(?:${w})(?:[^a-zа-я0-9]|$)`;
  const BRANDS = [['volkswagen|фольксваген|vw','Volkswagen'],['audi|ауди','Audi'],['bmw|бмв','BMW'],['mercedes|мерседес','Mercedes-Benz'],['opel|опель','Opel'],
    ['ford|форд','Ford'],['renault|рено','Renault'],['peugeot|пежо','Peugeot'],['citroen|ситроен','Citroen'],['toyota|тойота','Toyota'],['nissan|ниссан','Nissan'],
    ['mazda|мазда','Mazda'],['kia|киа','Kia'],['hyundai|хендай|хундай|хендэ','Hyundai'],['skoda|шкода','Skoda'],['lada|лада|ваз|vaz','Lada (ВАЗ)'],['geely|джили','Geely'],
    ['chevrolet|шевроле','Chevrolet'],['mitsubishi|митсубиси|мицубиси','Mitsubishi'],['honda|хонда','Honda'],['volvo|вольво','Volvo'],['fiat|фиат','Fiat'],
    ['daewoo|дэу','Daewoo'],['subaru|субару','Subaru'],['suzuki|сузуки','Suzuki'],['lexus|лексус','Lexus'],['land rover|range rover|ленд ровер','Land Rover'],
    ['chery|чери','Chery'],['haval|хавейл','Haval'],['belgee|белджи','Belgee'],['газ|gaz','ГАЗ'],['уаз|uaz','УАЗ'],['seat','Seat'],['dacia|дачия','Dacia']]
    .map(([re,t])=>[new RegExp(W(re)), t]);
  const KIND = {
    nedvizhimost:[['квартир','Квартиры'],['доля|доли','Доли'],['машино-?мест|гараж','Гаражи и машино-места'],['аренд','Право аренды'],['жилой дом|жилого дома|коттедж|'+W('дом'),'Жилые дома'],
      ['дач|садов','Дачи и садовые домики'],['незаверш','Незавершённое строительство'],['земельн|участ','Земельные участки'],['магазин|торгов','Торговые объекты'],
      ['склад|хранилищ','Склады'],['офис|административ','Офисы'],['производ|цех|завод|мастерск','Производственные'],['комплекс','Комплексы'],
      ['помещени','Помещения'],['здани|строени|сооружени','Здания и сооружения']],
    gruz:[['тягач','Тягачи'],['самосвал','Самосвалы'],['автобус','Автобусы'],['прицеп','Прицепы и полуприцепы'],['фургон|рефриж|изотерм','Фургоны'],['цистерн','Цистерны'],['бортов','Бортовые']],
    spec:[['трактор','Тракторы'],['экскаватор','Экскаваторы'],['погрузчик','Погрузчики'],['кран','Краны'],['комбайн','Комбайны'],['бульдозер','Бульдозеры'],['каток','Катки']],
    oborud:[['станок|станк','Станки'],['котел|котл','Котлы'],['компрессор','Компрессоры'],['генератор|электростанц','Генераторы'],['лини','Производственные линии'],['холодил|морозил','Холодильное'],['мебел','Мебель']]
  };
  Object.values(KIND).forEach(a=>a.forEach(x=>{ x[0] = new RegExp(x[0]); }));
  const OTHER = { nedvizhimost:'Прочая недвижимость', avto:'Прочие марки', gruz:'Прочая грузовая техника', spec:'Прочая спецтехника', oborud:'Прочее оборудование' };
  // площадки пишут латинские марки с русскими буквами («МITSUBISHI», «МAZ»): в словах, где есть латиница, русские двойники — в латиницу
  const HOMO = { 'а':'a', 'в':'b', 'е':'e', 'к':'k', 'м':'m', 'н':'h', 'о':'o', 'р':'p', 'с':'c', 'т':'t', 'у':'y', 'х':'x' };
  const unmix = s => s.replace(/[a-zа-я]+/g, w => /[a-z]/.test(w) && /[а-я]/.test(w) ? w.replace(/[авекмнорстух]/g, c=>HOMO[c]) : w);
  function kindOf(l){
    const n = ' ' + unmix(String(l.name||'').toLowerCase().replace(/ё/g,'е')) + ' ';
    const hit = (l.section==='avto' ? BRANDS : KIND[l.section] || []).find(([re])=>re.test(n));
    return hit ? hit[1] : OTHER[l.section] || 'Прочее';
  }

  const esc = s => String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const nf = n => n==null||n==='' ? '—' : Math.round(+n).toLocaleString('ru-RU');
  const p2 = n => String(n).padStart(2,'0');
  const plural = (n,a,b,c) => { n = Math.abs(n)%100; const m = n%10; return n>10&&n<20?c : m>1&&m<5?b : m===1?a : c; };
  const med = a => { if(!a.length) return null; const s = [...a].sort((x,y)=>x-y), m = s.length>>1; return s.length%2 ? s[m] : (s[m-1]+s[m])/2; };
  const big = n => n>=1e9 ? (n/1e9).toFixed(2).replace('.',',')+' млрд' : n>=1e6 ? (n/1e6).toFixed(1).replace('.',',')+' млн' : nf(n);
  const pc = (a, b) => b ? Math.round(a/b*100) + '%' : '—';
  const mt = v => v == null ? '—' : (v >= 0 ? '+' : '−') + Math.abs(Math.round(v)) + '%';   // цена продажи к начальной
  const dkey = t => { const d = new Date(t*1000); return `${d.getFullYear()}-${p2(d.getMonth()+1)}-${p2(d.getDate())}`; };
  const dshort = k => k.slice(8,10) + '.' + k.slice(5,7);
  const dt = s => { const d = new Date(s*1000); return `${p2(d.getDate())}.${p2(d.getMonth()+1)}.${d.getFullYear()}`; };

  // классы с приставкой bk-: у сайта свои .kpis/.kpi (на главной сдвинуты вверх) — не пересекаемся
  const CSS = `
  .bls .bk-kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;margin-bottom:16px}
  .bls .bk-kpi{background:#fff;border:1px solid #dde2e8;border-radius:10px;padding:12px 14px;box-shadow:0 1px 3px rgba(20,30,45,.08)}
  .bls .bk-kpi b{display:block;font-size:24px}
  .bls .bk-kpi span{color:#4a5563;font-size:13px}
  .bls .pnl{background:#fff;border:1px solid #dde2e8;border-radius:10px;padding:16px;box-shadow:0 1px 3px rgba(20,30,45,.08);margin-bottom:16px}
  .bls .pnl h2{font-size:16px;margin:0 0 10px}
  .bls .mut{color:#77818d;font-size:13px}
  .bls .tabs{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:14px}
  .bls .tabs a{padding:6px 12px;border-radius:16px;border:1px solid #c6cdd6;text-decoration:none;color:#1a2330;background:#fff;font-size:14px}
  .bls .tabs a.on{background:#12508f;border-color:#12508f;color:#fff}
  .bls .g2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
  .bls .cols{display:flex;align-items:flex-end;gap:3px;height:190px;padding-top:4px}
  .bls .col{flex:1;min-width:4px;max-width:56px;height:100%;display:flex;flex-direction:column;justify-content:flex-end;text-align:center}
  .bls .col b{font-size:10px;font-weight:600;color:#4a5563;min-height:13px;line-height:13px}
  .bls .col .stk{display:flex;flex-direction:column-reverse;border-radius:3px 3px 0 0;overflow:hidden;min-height:0}
  .bls .col .stk i{display:block;min-height:1px}
  .bls .col span{font-size:10px;color:#77818d;height:14px;line-height:14px;margin-top:3px;white-space:nowrap}
  .bls .lg{display:flex;gap:14px;flex-wrap:wrap;margin-top:10px;font-size:12px;color:#4a5563}
  .bls .lg i,.bls .dot{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
  .bls .hb-r{display:grid;grid-template-columns:minmax(110px,34%) 1fr auto;gap:10px;align-items:center;padding:4px 0}
  .bls .hb-l{font-size:13px;color:#4a5563}
  .bls .hb-t{background:#eef1f4;border-radius:4px;height:14px;overflow:hidden}
  .bls .hb-t i{display:block;height:100%;border-radius:4px}
  .bls .hb-v{font-size:13px;font-weight:600;white-space:nowrap}
  .bls .hb-v small{font-weight:400;color:#77818d}
  .bls .tw{overflow-x:auto}
  .bls table{border-collapse:collapse;width:100%}
  .bls th,.bls td{text-align:left;padding:7px 8px;border-bottom:1px solid #dde2e8;vertical-align:top;white-space:nowrap;font-size:14px}
  .bls th{font-weight:600;color:#4a5563;font-size:12px;text-transform:uppercase;letter-spacing:.02em}
  .bls td:first-child{white-space:normal;min-width:160px}
  .bls .heat{display:inline-block;min-width:34px;text-align:center;border-radius:4px;padding:1px 6px;font-weight:600}
  .bls .btn2{border:1px solid #c6cdd6;background:#fff;border-radius:6px;padding:7px 12px;cursor:pointer;font:inherit}
  .bls .fbar{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:flex-end;margin:-4px 0 16px}
  .bls .fbar label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#4a5563}
  .bls .fbar select{font:inherit;font-size:14px;padding:6px 8px;border:1px solid #c6cdd6;border-radius:6px;background:#fff;color:#1a2330;min-width:180px;max-width:280px}
  .bls .fbar .rst{font-size:13px;color:#b3261e;padding-bottom:8px}
  .bls .fnote{background:#eef4fb;border:1px solid #cfe0f2;border-radius:8px;padding:8px 12px;font-size:13px;margin-bottom:14px}
  .bls .sub{display:inline-block;padding-left:18px;color:#4a5563}
  @media (max-width:860px){ .bls .g2{grid-template-columns:1fr} }
  @media (max-width:600px){ .bls .fbar label{flex:1 1 100%} .bls .fbar select{max-width:none;width:100%} }`;
  function css(){ if(document.getElementById('bls-css')) return; const s = document.createElement('style'); s.id = 'bls-css'; s.textContent = CSS; document.head.appendChild(s); }

  function hbars(rows, unit=''){
    const max = Math.max(1, ...rows.map(r=>r[1]));
    return rows.map(([label, v, note, col])=>`<div class="hb-r"><span class="hb-l">${esc(label)}</span>
      <span class="hb-t"><i style="width:${Math.max(v?2:0, v/max*100)}%;background:${col||'#12508f'}"></i></span>
      <span class="hb-v">${nf(v)}${unit}${note?` <small>${esc(note)}</small>`:''}</span></div>`).join('');
  }
  function cols(days){
    const max = Math.max(1, ...days.map(d=>d.total)), every = Math.ceil(days.length/15);
    return `<div class="cols">${days.map((d,i)=>`<div class="col" title="${dshort(d.key)}: ${d.total}">
      <b>${d.total||''}</b><div class="stk" style="height:${d.total/max*100}%">${d.parts ? SECS.map(([s])=>d.parts[s]?`<i style="flex:${d.parts[s]};background:${COL[s]}"></i>`:'').join('') : '<i style="flex:1;background:#12508f"></i>'}</div>
      <span>${i%every===0?dshort(d.key):''}</span></div>`).join('')}</div>`;
  }
  const legend = () => `<div class="lg">${SECS.map(([s,t])=>`<span><i style="background:${COL[s]}"></i>${t}</span>`).join('')}</div>`;
  const tbl = (head, rows) => `<div class="tw"><table><tr>${head.map(h=>`<th>${h}</th>`).join('')}</tr>${rows.map(r=>`<tr>${r.map(c=>`<td>${c}</td>`).join('')}</tr>`).join('')}</table></div>`;
  function daysRange(fromTs){ const out = []; const d = new Date(fromTs*1000); d.setHours(12,0,0,0);
    const end = new Date(); end.setHours(12,0,0,0);
    for(; d <= end; d.setDate(d.getDate()+1)) out.push(dkey(d.getTime()/1000)); return out; }

  function render(el, o){
    css();
    const lots = o.lots || [], daily = o.daily || [], site = o.site || '';
    // фильтры: период, раздел, площадка, область, тип объекта («раздел|тип»)
    const f0 = o.f || { per:o.per, sec:o.sec };
    const f = { per:f0.per||'30', sec:f0.sec||'', plat:f0.plat||'', reg:f0.reg||'', kind:f0.kind||'' };
    const { per, sec, plat, reg, kind } = f;
    const on = new Set((o.blocks || BLOCKS.map(b=>b[0])).filter(b=>o.admin || !ADMIN_ONLY.includes(b)));
    const now = Date.now()/1000, from = per==='all' ? 0 : now - (+per)*86400;
    const regOf = l => REG.includes(l.region) ? l.region : 'не указан / другое';
    const regs = [...REG, 'не указан / другое'];
    const kOf = l => l._k || (l._k = (l.section||'') + '|' + kindOf(l));
    const inF = (l, skip) => (!sec || l.section===sec) && (!plat || l.platform===plat) && (!reg || regOf(l)===reg) && (skip==='kind' || !kind || kOf(l)===kind);
    const one = !!(sec || kind);   // выбрана одна категория — медианы цен и процентов сравнимы
    const market = lots.filter(l=>l.status==='active' && !['dup','hidden'].includes(l.hidden_why) && inF(l));
    const onSite = lots.filter(l=>l.status==='active' && l.published && inF(l));
    const seenFrom = Math.min(...lots.filter(l=>l.first_seen).map(l=>l.first_seen));
    const fresh = lots.filter(l=>l.first_seen && l.first_seen>=from && l.hidden_why!=='dup' && inF(l));
    const done = lots.filter(l=>l.status==='archive' && l.closed>=from && inF(l));
    const val = a => a.reduce((s,l)=>s+(+l.price||0),0);
    const disc = l => l.market && l.market.median && !l.market.manual ? Math.round((l.market.median - l.price)/l.market.median*100) : null;
    const discs = market.map(disc).filter(x=>x!==null);
    const perTxt = { '7':'7 дней', '30':'30 дней', '90':'90 дней', all:'всё время' }[per];
    const link = l => `<a href="${site}#/lot/${encodeURIComponent(l.id)}" target="_blank" rel="noopener">${esc((l.name||'').slice(0,70))}</a>`;
    const secsShown = SECS.filter(([s])=>(!sec||s===sec) && (!kind||kind.startsWith(s+'|')));
    const platsShown = PLATS.filter(p=>!plat||p===plat);
    const dotSec = s => `<span class="dot" style="background:${COL[s]}"></span>${esc(SEC_RU[s]||s)}`;
    const P = [];   // панели по порядку

    if(on.has('fresh')){
      const startTs = per==='all' ? (isFinite(seenFrom) ? seenFrom : now) : Math.max(from, isFinite(seenFrom) ? seenFrom : from);
      const byDay = {}; fresh.forEach(l=>{ const k = dkey(l.first_seen); const d = byDay[k] ||= { total:0, parts:{} }; d.total++; d.parts[l.section] = (d.parts[l.section]||0) + 1; });
      const days = daysRange(startTs).map(k=>({ key:k, total:(byDay[k]||{}).total||0, parts:(byDay[k]||{}).parts }));
      P.push(`<div class="pnl"><h2>Новые лоты по дням</h2>${days.length?cols(days):'<p class="mut">Нет данных.</p>'}${legend()}</div>`);
    }
    if(on.has('size')){
      let dyn, note = '';
      if(!plat && !reg && !kind){
        const dl = daily.filter(d=>per==='all' || new Date(d.day).getTime()/1000 >= from - 86400);
        dyn = dl.map(d=>{ const st = d.stats||{}; return { key:d.day, total: sec ? ((st.by_section||{})[sec]||0) : st.active||0, parts: sec ? null : st.by_section }; });
      } else {
        // под площадку, область или тип снимков дня нет — восстанавливаем по лотам: на рынке с появления до закрытия приёма заявок
        const pool = lots.filter(l=>l.first_seen && !['dup','hidden'].includes(l.hidden_why) && inF(l));
        const startTs = per==='all' ? (isFinite(seenFrom) ? seenFrom : now) : Math.max(from, isFinite(seenFrom) ? seenFrom : from);
        dyn = daysRange(startTs).map(k=>{ const end = new Date(k + 'T23:59:59').getTime()/1000, parts = {};
          const xs = pool.filter(l=>l.first_seen<=end && (l.status==='active' || (l.closed||0) > end)); xs.forEach(l=>parts[l.section] = (parts[l.section]||0) + 1);
          return { key:k, total:xs.length, parts: sec ? null : parts }; });
        note = '<p class="mut">С фильтром по площадке, области или типу — по лотам, которые робот видел на рынке.</p>';
      }
      P.push(`<div class="pnl"><h2>Размер рынка по дням</h2>${dyn.length>=2 ? cols(dyn) + (sec?'':legend()) + note
        : `<p class="mut">Снимок рынка сохраняется раз в день. Первый — ${dyn[0]?dshort(dyn[0].key):'сегодня'}; график появится со второго дня.</p>`}</div>`);
    }
    if(on.has('plat')){
      const win = xs => { const w = med(xs.filter(l=>l.req_to>l.first_seen).map(l=>(l.req_to-l.first_seen)/86400)); return w!=null ? Math.round(w)+' дн.' : '—'; };
      if(one){
        // одна категория: цены площадок сравнимы
        const rows = platsShown.map(p=>{ const m = market.filter(l=>l.platform===p), f2 = fresh.filter(l=>l.platform===p), s = onSite.filter(l=>l.platform===p);
          const merged = lots.filter(l=>l.platform===p && l.status==='active' && l.hidden_why==='dup' && inF(l)).length;
          return m.length || f2.length ? [esc(p), nf(s.length), nf(m.length) + (merged?` <small class="mut">+${merged} дубл.</small>`:''), pc(m.length, market.length), nf(f2.length),
            big(val(m)), nf(med(m.map(l=>+l.price).filter(x=>x>0))), m.length ? win(f2) : '—'] : null; }).filter(Boolean);
        P.push(`<div class="pnl"><h2>Площадки</h2>${rows.length ? tbl(['Площадка','На сайте','На рынке','Доля','Новых за период','Сумма стартовых цен, BYN','Медианная цена, BYN','Окно подачи заявок'], rows) : '<p class="mut">Нет лотов.</p>'}
          <p class="mut">Окно подачи заявок — медиана дней от появления лота до конца приёма заявок. «Дубл.» — лоты, склеенные с карточкой другой площадки.</p></div>`);
      } else {
        // все разделы: цены разных категорий не смешиваем — только сколько лотов в каком разделе
        const rows = platsShown.map(p=>{ const m = market.filter(l=>l.platform===p); if(!m.length && !fresh.some(l=>l.platform===p)) return null;
          return [esc(p), ...secsShown.map(([s])=>{ const v = m.filter(l=>l.section===s).length; return v ? nf(v) : '<span class="mut">·</span>'; }),
            `<b>${nf(m.length)}</b>`, pc(m.length, market.length), nf(fresh.filter(l=>l.platform===p).length), win(fresh.filter(l=>l.platform===p))]; }).filter(Boolean);
        P.push(`<div class="pnl"><h2>Площадки</h2>${tbl(['Площадка', ...secsShown.map(([,t])=>t), 'Всего на рынке', 'Доля', 'Новых за период', 'Окно подачи заявок'], rows)}
          <p class="mut">Цены по площадкам — при выбранном разделе: у квартиры и трактора разные цены, общая медиана ничего не говорит.</p></div>`);
      }
    }
    if(on.has('sec')){
      const rows = secsShown.map(([s,t])=>{ const m = market.filter(l=>l.section===s), pr = m.map(l=>+l.price).filter(x=>x>0), ds = m.map(disc).filter(x=>x!==null);
        return [dotSec(s), nf(m.length), nf(fresh.filter(l=>l.section===s).length), nf(done.filter(l=>l.section===s).length),
          big(val(m)), nf(med(pr)), pr.length?nf(Math.min(...pr)):'—', pr.length?big(Math.max(...pr)):'—', ds.length?Math.round(med(ds))+'%':'—']; });
      P.push(`<div class="pnl"><h2>Разделы</h2>${tbl(['Раздел','На рынке','Новых','Закрылось','Сумма, BYN','Медиана, BYN','Мин.','Макс.','Скидка к рынку'], rows)}</div>`);
    }
    if(on.has('reg')){
      const cell = {}; market.forEach(l=>{ const k = regOf(l)+'|'+l.section; cell[k] = (cell[k]||0)+1; });
      const cmax = Math.max(1, ...Object.values(cell));
      const rows = regs.map(r=>{ const tot = market.filter(l=>regOf(l)===r).length; if(!tot) return null;
        return [esc(r), ...secsShown.map(([s])=>{ const v = cell[r+'|'+s]||0; return v ? `<span class="heat" style="background:rgba(18,80,143,${(0.08+0.6*v/cmax).toFixed(2)})">${v}</span>` : '<span class="mut">·</span>'; }),
          `<b>${nf(tot)}</b>`, big(val(market.filter(l=>regOf(l)===r)))]; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Регионы</h2>${tbl(['Регион', ...secsShown.map(([,t])=>t), 'Всего', 'Сумма, BYN'], rows)}</div>`);
    }
    const pair = [];
    if(on.has('prices')){
      const B = [[0,5e3,'до 5 тыс.'],[5e3,2e4,'5–20 тыс.'],[2e4,5e4,'20–50 тыс.'],[5e4,1e5,'50–100 тыс.'],[1e5,5e5,'100–500 тыс.'],[5e5,Infinity,'от 500 тыс.']];
      pair.push(`<div class="pnl"><h2>Стартовые цены</h2>${hbars(B.map(([a,b,t])=>{ const n = market.filter(l=>l.price>=a && l.price<b).length; return [t+' BYN', n, pc(n, market.length)]; }))}</div>`);
    }
    if(on.has('disc')){
      const D = [[-1e9,0,'дороже рынка'],[0,20,'дешевле на 0–20%'],[20,40,'на 20–40%'],[40,60,'на 40–60%'],[60,1e9,'на 60% и больше']];
      pair.push(`<div class="pnl"><h2>Скидка к рынку</h2>${discs.length?hbars(D.map(([a,b,t],i)=>[t, discs.filter(d=>d>=a && d<b).length, '', i===0?'#b3261e':i>=3?'#1d7a4d':'#12508f'])):'<p class="mut">Нет лотов с ориентиром.</p>'}
        <p class="mut">По лотам, у которых нашёлся рыночный ориентир на Kufar.</p></div>`);
    }
    if(pair.length) P.push(pair.length===2 ? `<div class="g2">${pair.join('')}</div>` : pair[0]);
    if(on.has('soon')){
      const soon = {}; onSite.forEach(l=>{ if(l.req_to>now && l.req_to<now+14*86400){ const k = dkey(l.req_to); const d = soon[k] ||= { total:0, parts:{} }; d.total++; d.parts[l.section] = (d.parts[l.section]||0)+1; } });
      const days = []; for(let i=0;i<14;i++){ const k = dkey(now + i*86400); days.push({ key:k, total:(soon[k]||{}).total||0, parts:(soon[k]||{}).parts }); }
      P.push(`<div class="pnl"><h2>Закрытие приёма заявок — ближайшие 14 дней</h2>${cols(days)}${legend()}</div>`);
    }
    const pair2 = [];
    if(on.has('sqm') && (!sec || sec==='nedvizhimost')){
      const realty = market.filter(l=>l.section==='nedvizhimost' && +l.area_num>0 && +l.area_num<=1000 && +l.price>0);
      const sqm = regs.map(r=>{ const a = realty.filter(l=>regOf(l)===r).map(l=>l.price/l.area_num); return a.length ? [r, Math.round(med(a)), `${a.length} ${plural(a.length,'объект','объекта','объектов')}`] : null; }).filter(Boolean).sort((a,b)=>b[1]-a[1]);
      pair2.push(`<div class="pnl"><h2>Недвижимость: медианная цена м²</h2>${sqm.length?hbars(sqm,' BYN'):'<p class="mut">Нет лотов с указанной площадью.</p>'}
        <p class="mut">Стартовая цена, делённая на площадь. Объекты до 1 000 м² — квартиры, дома, помещения; комплексы и заводы не учитываются.</p></div>`);
    }
    if(on.has('sellers')){
      const sl = {}; market.forEach(l=>{ const d = (l.debtor||'').trim(); if(!d || /^(Конфискованное имущество|Физическое лицо)$/.test(d)) return; const x = sl[d] ||= { n:0, v:0 }; x.n++; x.v += +l.price||0; });
      const top = Object.entries(sl).sort((a,b)=>b[1].n-a[1].n).slice(0,12);
      pair2.push(`<div class="pnl"><h2>Крупнейшие продавцы</h2><p class="mut" style="margin-top:0">По числу лотов на рынке; конфискат и физлица не в счёт.</p>
        ${top.length?tbl(['Должник / продавец','Лотов','Сумма, BYN'], top.map(([d,x])=>[esc(d.slice(0,80)), nf(x.n), big(x.v)])):'<p class="mut">Нет данных.</p>'}</div>`);
    }
    if(pair2.length) P.push(pair2.length===2 ? `<div class="g2">${pair2.join('')}</div>` : pair2[0]);
    if(on.has('topdisc')){
      const top = market.filter(l=>disc(l)!==null).sort((a,b)=>disc(b)-disc(a)).slice(0,10);
      P.push(`<div class="pnl"><h2>Самая большая скидка к рынку</h2>${top.length?tbl(['Лот','Раздел','Площадка','Цена, BYN','Рынок, BYN','Скидка'], top.map(l=>[link(l), esc(SEC_RU[l.section]||''), esc(l.platform), nf(l.price), nf(l.market.median), `<b>${disc(l)}%</b>`])):'<p class="mut">Нет данных.</p>'}
        <p class="mut">Большая скидка бывает и ошибкой сравнения: сравниваются обычные объявления, состояние объекта не учитывается.</p></div>`);
    }
    if(on.has('drops')){
      const drops = market.filter(l=>+l.price0>0 && +l.price<+l.price0).map(l=>[l, Math.round((l.price0-l.price)/l.price0*100)]).sort((a,b)=>b[1]-a[1]);
      P.push(`<div class="pnl"><h2>Снижение цены (повторные торги)</h2>${drops.length?`<p style="margin-top:0">${nf(drops.length)} ${plural(drops.length,'лот подешевел','лота подешевели','лотов подешевели')} с момента появления, медиана снижения — ${Math.round(med(drops.map(x=>x[1])))}%.</p>`
        + tbl(['Лот','Раздел','Площадка','Было, BYN','Стало, BYN','Снижение'], drops.slice(0,10).map(([l,d])=>[link(l), esc(SEC_RU[l.section]||''), esc(l.platform), nf(l.price0), nf(l.price), `<b>−${d}%</b>`]))
        : '<p class="mut">Пока ни один лот не подешевел — история цен копится с 24.09.2026.</p>'}</div>`);
    }
    // Итоги и продажи: проценты и цены считаем внутри раздела (и площадки в разделе), а не по площадке целиком —
    // у квартиры, трактора и станка разные цены и разная конкуренция
    const HR = ['Завершилось торгов','Продано','Доля продаж','Цена продажи к начальной (медиана)','Цена продажи, BYN (медиана)','Участников (медиана)'];
    const statRow = (label, xs, g) => { const s = xs.filter(g.sold), p = s.map(g.pm).filter(v=>v!==null), u = xs.map(g.users).filter(v=>v>0);
      return [label, nf(xs.length), nf(s.length), xs.length >= 3 && !s.length ? '<b style="color:#b3261e">0% — не продаётся</b>' : pc(s.length, xs.length), mt(med(p)),
        s.length ? nf(med(s.map(g.price))) : '—', u.length ? nf(med(u)) : '—']; };
    // раздел → площадки внутри раздела; при выбранном разделе — ещё и типы объектов
    const bySecPlat = (xs, g) => { const rows = [];
      secsShown.forEach(([s])=>{ const a = xs.filter(x=>x.section===s); if(!a.length) return;
        rows.push(statRow(`<b>${dotSec(s)}</b>`, a, g).map((c,i)=>i ? `<b>${c}</b>` : c));
        platsShown.forEach(p=>{ const b = a.filter(x=>x.platform===p); if(b.length) rows.push(statRow(`<span class="sub">${esc(p)}</span>`, b, g)); }); });
      return rows; };
    const byKindRows = (xs, g) => Object.entries(xs.reduce((m,x)=>{ (m[kOf(x)] ||= []).push(x); return m; }, {}))
      .sort((a,b)=>b[1].filter(g.sold).length - a[1].filter(g.sold).length || b[1].length - a[1].length).slice(0,30)
      .map(([k,a])=>statRow(esc(k.split('|')[1]) + (sec ? '' : ` <small class="mut">${esc(SEC_RU[k.split('|')[0]]||'')}</small>`), a, g));
    const BF = '<p class="mut">Итоги копятся с 26.08.2026: торги, завершённые за месяц до запуска, загружены из архивов площадок, дальше робот собирает итоги сам после даты торгов.</p>';
    if(on.has('results')){
      // итоги торгов по лотам, торги которых закончились в выбранный период
      const ST = { sold:['Продан','#1d7a4d'], single:['Продан единственному участнику','#4cae7d'], failed:['Не состоялись','#d9761f'], cancelled:['Отменены','#9aa3ad'] };
      const g = { sold:l=>(l.result.st==='sold' || l.result.st==='single') && l.result.price > 0,
                  pm:l=>l.result.start > 0 && l.result.price > 0 ? (l.result.price / l.result.start - 1) * 100 : null,
                  price:l=>+l.result.price, users:l=>+l.result.users||0 };
      const fin = lots.filter(l=>l.status==='archive' && l.result && ST[l.result.st] && inF(l) && (l.result.at || l.closed) >= from);
      const sold = fin.filter(g.sold);
      const pr = sold.filter(l=>g.pm(l)!==null).map(l=>[l, Math.round(g.pm(l))]).sort((a,b)=>b[1]-a[1]);
      P.push(`<div class="pnl"><h2>Итоги торгов</h2>${fin.length ? `<p style="margin-top:0">Торги закончились по <b>${nf(fin.length)}</b> ${plural(fin.length,'лоту','лотам','лотам')}: продано ${nf(sold.length)} (${pc(sold.length, fin.length)})${
          one && pr.length ? `, медианная цена продажи — <b>${mt(med(pr.map(x=>x[1])))}</b> к начальной` : ''}.${one ? '' : ' Цены и проценты — по разделам: у разных категорий они несравнимы.'}</p>
        ${hbars(Object.entries(ST).map(([k,[t,c]])=>[t, fin.filter(l=>l.result.st===k).length, pc(fin.filter(l=>l.result.st===k).length, fin.length), c]))}
        <h2 style="margin-top:14px">По разделам и площадкам</h2>${tbl(['Раздел / площадка', ...HR], bySecPlat(fin, g))}
        ${one ? `<h2 style="margin-top:14px">По типам объектов</h2>${tbl(['Тип объекта', ...HR], byKindRows(fin, g))}` : ''}
        ${pr.length ? `<h2 style="margin-top:14px">Самый большой рост цены на торгах</h2>` + tbl(['Лот','Раздел','Площадка','Начальная, BYN','Продан за, BYN','Рост'], pr.slice(0,10).map(([l,d])=>[link(l), esc(SEC_RU[l.section]||''), esc(l.platform), nf(l.result.start), nf(l.result.price), `<b>${d>=0?'+':''}${d}%</b>`])) : ''}${BF}`
        : '<p class="mut">За выбранный период и фильтры итогов нет.</p>' + BF}</div>`);
    }
    if(on.has('sales') && o.sales){
      // Продажи на торгах: по постоянной таблице sales — итоги копятся дольше архива (180 дней)
      const S = o.sales.filter(x=>inF(x) && x.at >= from);
      const g = { sold:x=>(x.st==='sold' || x.st==='single') && x.price > 0, pm:x=>x.start > 0 && x.price > 0 ? (x.price / x.start - 1) * 100 : null,
                  price:x=>+x.price, users:x=>+x.users||0 };
      if(!S.length){
        P.push(`<div class="pnl"><h2>Продажи на торгах</h2><p class="mut">За выбранный период и фильтры итогов нет.</p>${BF}</div>`);
      } else {
        const sold = S.filter(g.sold), pms = sold.map(g.pm).filter(v=>v!==null), sum = sold.reduce((a,x)=>a+ +x.price,0);
        const B = [[-1e9,-0.5,'Дешевле начальной','#d9761f'],[-0.5,0.5,'По начальной цене','#7b8794'],[0.5,5.5,'До +5%','#8fbfa6'],[5.5,20,'+5…20%','#4cae7d'],
                   [20,50,'+20…50%','#2f9464'],[50,100,'+50…100%','#1d7a4d'],[100,1e9,'Больше +100%','#145c39']];
        const inB = (v, [a,b]) => v >= a && v < b;
        // распределение цены продажи: при одной категории — полосы, при всех — по разделам
        const distr = one ? (pms.length ? hbars(B.map(bk=>{ const n = pms.filter(v=>inB(v, bk)).length; return [bk[2], n, pc(n, pms.length), bk[3]]; })) : '<p class="mut">Продаж пока нет.</p>')
          : tbl(['Раздел', ...B.map(bk=>bk[2]), 'Медиана'], secsShown.map(([s])=>{ const v = sold.filter(x=>x.section===s).map(g.pm).filter(x=>x!==null); if(!v.length) return null;
              return [dotSec(s), ...B.map(bk=>{ const n = v.filter(x=>inB(x, bk)).length; return n ? `${n} <small class="mut">${pc(n, v.length)}</small>` : '<span class="mut">·</span>'; }), `<b>${mt(med(v))}</b>`]; }).filter(Boolean));
        // регионы: при одной категории — таблица с ценами; при всех — где продаётся, по разделам (продано / завершилось)
        const regRows = regs.map(r=>{ const a = S.filter(x=>regOf(x)===r); return a.length ? [r, a] : null; }).filter(Boolean).sort((a,b)=>b[1].length-a[1].length);
        const regTbl = one ? tbl(['Регион', ...HR], regRows.map(([r,a])=>statRow(esc(r), a, g)))
          : tbl(['Регион', ...secsShown.map(([,t])=>t), 'Всего'], regRows.map(([r,a])=>[esc(r), ...secsShown.map(([s])=>{ const b = a.filter(x=>x.section===s); if(!b.length) return '<span class="mut">·</span>';
              const n = b.filter(g.sold).length, sh = n / b.length; return `<span class="heat" style="background:${b.length >= 3 && !n ? 'rgba(179,38,30,.18)' : `rgba(29,122,77,${(0.08+0.55*sh).toFixed(2)})`}" title="продано ${n} из ${b.length}">${n}/${b.length}</span>`; }),
              `${a.filter(g.sold).length}/${a.length} <small class="mut">${pc(a.filter(g.sold).length, a.length)}</small>`]));
        const UB = [[1,1,'1 участник'],[2,2,'2 участника'],[3,5,'3–5 участников'],[6,1e9,'6 и больше']];
        const compRows = xs => UB.map(([a,b,t])=>{ const s = xs.filter(x=>x.users >= a && x.users <= b), p = s.map(g.pm).filter(v=>v!==null);
          return s.length ? [t, nf(s.length), mt(med(p)), nf(med(s.map(x=>+x.bids||0)))] : null; }).filter(Boolean);
        const comp = one ? compRows(sold) : secsShown.flatMap(([s])=>{ const r = compRows(sold.filter(x=>x.section===s)); return r.length ? [[`<b>${dotSec(s)}</b>`,'','',''], ...r.map(x=>[`<span class="sub">${x[0]}</span>`, ...x.slice(1)])] : []; });
        const byKind = Object.entries(S.reduce((m,x)=>{ (m[kOf(x)] ||= []).push(x); return m; }, {}));
        const dead = [...byKind.filter(([,xs])=>xs.length >= 3 && !xs.some(g.sold)).map(([k,xs])=>k.split('|')[1] + (sec ? '' : ` (${SEC_RU[k.split('|')[0]]||''})`) + ' · ' + xs.length),
                      ...(one ? regRows.filter(([,xs])=>xs.length >= 3 && !xs.some(g.sold)).map(([r,xs])=>r + ' · ' + xs.length) : [])];
        const topP = [...sold].sort((a,b)=>b.price-a.price).slice(0,10), topR = sold.filter(x=>g.pm(x)!==null).sort((a,b)=>g.pm(b)-g.pm(a)).slice(0,10);
        const below = sold.filter(x=>g.pm(x)!==null && g.pm(x) < -0.5).sort((a,b)=>g.pm(a)-g.pm(b)).slice(0,10);
        const lt = xs => tbl(['Лот','Раздел','Площадка','Регион','Начальная, BYN','Продан за, BYN','К начальной','Участников'],
          xs.map(x=>[link(x), esc(SEC_RU[x.section]||''), esc(x.platform), esc(x.region||'—'), nf(x.start), `<b>${nf(x.price)}</b>`, mt(g.pm(x)), x.users || '—']));
        P.push(`<div class="pnl"><h2>Продажи на торгах</h2>
          <div class="bk-kpis">
            <div class="bk-kpi"><b>${nf(S.length)}</b><span>торгов завершилось</span></div>
            <div class="bk-kpi"><b>${nf(sold.length)}</b><span>продано — ${pc(sold.length, S.length)}</span></div>
            <div class="bk-kpi"><b>${big(sum)}</b><span>BYN — сумма продаж</span></div>
            ${one ? `<div class="bk-kpi"><b>${mt(med(pms))}</b><span>медиана цены продажи к начальной</span></div>
            <div class="bk-kpi"><b>${pc(pms.filter(v=>v > 0.5).length, pms.length)}</b><span>продано дороже начальной</span></div>
            <div class="bk-kpi"><b>${pc(pms.filter(v=>v < -0.5).length, pms.length)}</b><span>продано дешевле начальной</span></div>` : ''}
          </div>
          ${one ? '' : `<h2>По разделам и площадкам</h2>${tbl(['Раздел / площадка', ...HR], bySecPlat(S, g))}
            <p class="mut">Цены и проценты считаются внутри раздела. Выберите раздел или тип объекта — появятся медианы по категории.</p>`}
          ${one ? `<h2 style="margin-top:16px">Площадки</h2>${tbl(['Площадка', ...HR], platsShown.map(p=>[p, S.filter(x=>x.platform===p)]).filter(([,a])=>a.length).map(([p,a])=>statRow(esc(p), a, g)))}` : ''}
          <h2 style="margin-top:16px">Цена продажи относительно начальной</h2>${distr}
          <h2 style="margin-top:16px">Регионы: где продаётся</h2>${regTbl}${one ? '' : '<p class="mut">В ячейке — продано / завершилось торгов. Красным — три и больше торгов без продаж.</p>'}
          <h2 style="margin-top:16px">Какие объекты продаются</h2>${tbl(['Тип объекта', ...HR], byKindRows(S, g))}
          <p class="mut">Тип определяется по названию лота, у легковых — марка.</p>
          ${comp.length ? `<h2 style="margin-top:16px">Конкуренция: чем больше участников, тем дороже</h2>${tbl(['Участников','Продано','Цена продажи к начальной (медиана)','Ставок (медиана)'], comp)}` : ''}
          ${dead.length ? `<h2 style="margin-top:16px">Не продаётся</h2><p style="margin-top:0">Три и больше завершённых торгов — и ни одной продажи: ${dead.map(esc).join(' · ')}</p>` : ''}
          ${topP.length ? `<h2 style="margin-top:16px">Самые дорогие продажи</h2>${lt(topP)}` : ''}
          ${topR.length ? `<h2 style="margin-top:16px">Самый большой рост цены</h2>${lt(topR)}` : ''}
          ${below.length ? `<h2 style="margin-top:16px">Проданы дешевле начальной</h2><p class="mut" style="margin-top:0">Торги на понижение и повторные торги со сниженной ценой.</p>${lt(below)}` : ''}
          ${BF}
        </div>`);
      }
    }
    if(on.has('quality')){
      const rows = platsShown.map(p=>{ const m = market.filter(l=>l.platform===p); if(!m.length) return null;
        return [esc(p), nf(m.length), pc(m.filter(l=>!l.photo).length, m.length), pc(m.filter(l=>!(+l.price>0)).length, m.length),
          pc(m.filter(l=>!(l.location||'').trim()).length, m.length), pc(m.filter(l=>(l.reasons||[]).includes('rule_deadline')).length, m.length), pc(m.filter(l=>l.market).length, m.length)]; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Качество данных площадок</h2>${tbl(['Площадка','Лотов','Без фото','Без цены','Без города','Срок по правилу','С ориентиром'], rows)}</div>`);
    }
    if(on.has('demand') && (o.leads || o.bots)){
      const lp = (o.leads||[]).filter(r=>new Date(r.created_at).getTime()/1000 >= from);
      const LS = { new:'новые', work:'в работе', deal:'сделка', refused:'отказ' };
      const bp = (o.bots||[]).filter(r=>new Date(r.at).getTime()/1000 >= from), botBy = {};
      bp.forEach(r=>Object.entries((r.stats||{}).by||{}).forEach(([p,n])=>botBy[p] = (botBy[p]||0) + n));
      P.push(`<div class="g2"><div class="pnl"><h2>Заявки за ${perTxt}</h2><p style="margin-top:0"><b>${nf(lp.length)}</b> ${plural(lp.length,'заявка','заявки','заявок')}${lp.length?': '+Object.entries(LS).map(([k,t])=>`${t} — ${lp.filter(r=>r.status===k).length}`).join(', '):''}.</p>
          <p class="mut">Конверсия в заявку появится, когда подключим счётчик посещений. Фильтры раздела, площадки и области к заявкам не применяются.</p></div>
        <div class="pnl"><h2>Telegram-бот за ${perTxt}</h2><p style="margin-top:0">Отправлено <b>${nf(bp.reduce((s,r)=>s+r.sent,0))}</b>.</p>${Object.keys(botBy).length?hbars(Object.entries(botBy).sort((a,b)=>b[1]-a[1]).map(([p,n])=>[p,n])):''}</div></div>`);
    }

    // ── панель фильтров ──
    const href = o.href || (() => '#');
    const H = ch => href(Object.assign({}, f, ch));
    // типы объектов — те, что есть в данных при остальных фильтрах; при всех разделах — группами по разделам
    const kc = {}; lots.forEach(l=>{ if(l.hidden_why!=='dup' && inF(l, 'kind')) kc[kOf(l)] = (kc[kOf(l)]||0) + 1; });
    const kindOpts = SECS.filter(([s])=>!sec || s===sec).map(([s,t])=>{ const ks = Object.entries(kc).filter(([k])=>k.startsWith(s+'|')).sort((a,b)=>b[1]-a[1]);
      if(!ks.length) return '';
      const opts = ks.map(([k,n])=>`<option value="${esc(k)}"${k===kind?' selected':''}>${esc(k.split('|')[1])} (${n})</option>`).join('');
      return sec ? opts : `<optgroup label="${esc(t)}">${opts}</optgroup>`; }).join('');
    const sel = (key, label, first, opts) => `<label>${label}<select data-f="${key}"><option value="">${first}</option>${opts}</select></label>`;
    const active = [plat, reg !== '' ? reg : '', kind ? kind.split('|')[1] : ''].filter(Boolean);
    const bar = `<div class="tabs">${[['7','7 дней'],['30','30 дней'],['90','90 дней'],['all','Всё время']].map(([k,t])=>`<a href="${H({ per:k })}" class="${k===per?'on':''}">${t}</a>`).join('')}
        <span style="width:12px"></span><a href="${H({ sec:'', kind:'' })}" class="${!sec?'on':''}">Все разделы</a>${SECS.map(([k,t])=>`<a href="${H({ sec:k, kind: kind.startsWith(k+'|') ? kind : '' })}" class="${k===sec?'on':''}">${t}</a>`).join('')}</div>
      <div class="fbar">
        ${sel('plat', 'Площадка', 'Все площадки', PLATS.map(p=>`<option${p===plat?' selected':''}>${esc(p)}</option>`).join(''))}
        ${sel('reg', 'Область', 'Все области', regs.map(r=>`<option${r===reg?' selected':''}>${esc(r)}</option>`).join(''))}
        ${sel('kind', 'Тип объекта', sec ? 'Все типы раздела' : 'Все типы', kindOpts)}
        ${active.length ? `<a class="rst" href="${H({ plat:'', reg:'', kind:'' })}">Сбросить фильтры</a>` : ''}
      </div>
      ${active.length ? `<div class="fnote">Показано: ${esc([sec ? SEC_RU[sec] : 'все разделы', ...active].join(' · '))} · ${perTxt}</div>` : ''}`;
    el.innerHTML = `<div class="bls">
      ${bar}
      ${on.has('kpi')?`<div class="bk-kpis">
        <div class="bk-kpi"><b>${nf(market.length)}</b><span>лотов на рынке сейчас${o.admin?` (на сайте ${nf(onSite.length)})`:''}</span></div>
        <div class="bk-kpi"><b>${nf(fresh.length)}</b><span>новых за ${perTxt}</span></div>
        <div class="bk-kpi"><b>${nf(done.filter(l=>l.why==='deadline').length)}</b><span>закрыт приём заявок за ${perTxt}</span></div>
        <div class="bk-kpi"><b>${nf(done.filter(l=>l.why==='removed').length)}</b><span>снято площадками досрочно</span></div>
        <div class="bk-kpi"><b>${big(val(market))}</b><span>BYN — сумма стартовых цен на рынке</span></div>
        <div class="bk-kpi"><b>${discs.length?Math.round(med(discs))+'%':'—'}</b><span>медианная скидка к рынку (${nf(discs.length)} ${plural(discs.length,'лот','лота','лотов')} с ориентиром)</span></div>
      </div>`:''}
      ${P.join('')}
      ${on.has('csv')?`<p><button class="btn2" type="button" data-bls-csv>Выгрузить рынок в Excel (CSV)</button> <span class="mut">${nf(market.length)} лотов с текущими фильтрами</span></p>`:''}
      <p class="mut">Рынок — активные лоты всех площадок без дублей. Учёт новых лотов ведётся с ${isFinite(seenFrom)?dt(seenFrom):'—'}; лоты, загруженные из архивов площадок, в новые не входят.</p>
    </div>`;
    el.querySelectorAll('select[data-f]').forEach(s=>s.onchange = () => {
      const ch = { [s.dataset.f]: s.value };
      if(s.dataset.f==='kind' && s.value && !sec) ch.sec = '';   // тип несёт раздел в себе
      location.href = H(ch);
    });
    const b = el.querySelector('[data-bls-csv]');
    if(b) b.onclick = () => {
      const C = [['Площадка','platform'],['Раздел',l=>SEC_RU[l.section]||l.section],['Тип объекта',l=>kOf(l).split('|')[1]],['Название','name'],['Стартовая цена, BYN','price'],['Первая цена, BYN','price0'],
        ['Заявки до',l=>{ const d = new Date(l.req_to*1000); return dt(l.req_to)+' '+p2(d.getHours())+':'+p2(d.getMinutes()); }],['Регион','region'],['Место','location'],['Продавец','debtor'],['Площадь, м²','area_num'],
        ['Рынок, BYN',l=>l.market&&l.market.median||''],['Скидка к рынку, %',l=>disc(l)??''],['Ссылка','url']];
      const cv = v => { const s = String(v==null?'':v); return /[;"\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s; };
      const csv = '﻿' + [C.map(c=>c[0]).join(';'), ...market.map(l=>C.map(([,fn])=>cv(typeof fn==='function'?fn(l):l[fn])).join(';'))].join('\r\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type:'text/csv;charset=utf-8' }));
      a.download = `bellot-rynok-${dkey(now)}.csv`; a.click(); setTimeout(()=>URL.revokeObjectURL(a.href), 2000);
    };
  }

  // Колонки копии каталога, нужные аналитике
  const FIELDS = 'id,name,url,platform,section,price,price0,req_to,first_seen,closed,why,status,published,hidden_why,region,location,market,reasons,photo,area_num,debtor,result';
  window.BLStats = { render, BLOCKS, ADMIN_ONLY, FIELDS, DEFAULT_CAB: BLOCKS.map(b=>b[0]).filter(b=>!ADMIN_ONLY.includes(b) && b!=='sales') };
})();
