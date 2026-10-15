/* МониТорг — аналитика рынка. Общая для админки и личного кабинета.
   Считается в браузере по копии каталога (таблица lots) и снимкам дня (daily).
   Рынок — активные лоты всех площадок без дублей и без скрытых админом.

   BLStats.render(el, { lots, daily, leads, bots, sales, runs, misses, f, blocks, href, site })
     f — фильтры { tab, per, sec, plat, reg, city, kind }: вкладка, период (7/30/90/all), раздел, площадка, область, город/район,
         тип объекта («раздел|тип»). Вкладки (15.10): Рынок сейчас, Цены, Итоги и продажи, Продавцы и площадки, Служебное (админка)
     blocks — какие блоки показать (id из BLStats.BLOCKS); по умолчанию все
     href(f) — ссылка на аналитику с такими фильтрами
     site — путь к сайту для ссылок на лоты ('../' из админки, '' с сайта)
     leads, bots — только для админки (блок «Заявки и бот»)
     sales — итоги завершённых торгов из постоянной таблицы sales (с городом и кругом торгов — из файла аналитики)
     runs, misses — только для админки: обходы робота и поиски без результатов (вкладка «Служебное») */
(function(){
  const BLOCKS = [
    ['kpi', 'Главные цифры'], ['days', 'По дням: новые лоты, размер рынка, закрытие заявок'], ['cut', 'Из чего состоит рынок: разделы, регионы, города'],
    ['prices', 'Стартовые цены'], ['disc', 'Скидка к рынку'], ['sqm', 'Недвижимость: цена м²'], ['drops', 'Снижение цены'],
    ['sales', 'Итоги торгов: чем закончились, за сколько продают'], ['months', 'Продажи по месяцам'], ['rounds', 'Повторные торги: круг за кругом'],
    ['chance', 'Шанс продажи по стартовой цене'], ['sellers', 'Крупнейшие продавцы'], ['platstat', 'Площадки'], ['csv', 'Выгрузка в Excel'],
    ['robot', 'Обход площадок и итоги'], ['search0', 'Поиски без результатов'], ['quality', 'Качество данных площадок'], ['demand', 'Заявки и Telegram-бот']
  ];
  const ADMIN_ONLY = ['robot', 'search0', 'quality', 'demand'];   // в кабинет не отдаются, даже если отмечены
  const SECS = [['nedvizhimost','Недвижимость'],['avto','Легковые авто'],['gruz','Грузовые и автобусы'],['spec','Спецтехника'],['oborud','Оборудование'],['arenda','Право аренды']];
  const SEC_RU = Object.fromEntries(SECS);
  const PLATS = ['e-auction.by','ipmtorgi.by','beltorgi.by','konfiskat.by','belauction.by','minskestate.by','mgcn.by','auction24.by','butb.by','lotsale.by','gostorg.by','bankrot-torg.by','specrealization.by','torgi.gov.by','etpvit.by','expert-torgi.by','realtorgi.by','iintorgi.by'];
  const COL = { nedvizhimost:'#12508f', avto:'#d9761f', gruz:'#1d7a4d', spec:'#7a4fa3', oborud:'#7b8794', arenda:'#a0572a' };
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
    oborud:[['станок|станк','Станки'],['котел|котл','Котлы'],['компрессор','Компрессоры'],['генератор|электростанц','Генераторы'],['лини','Производственные линии'],['холодил|морозил','Холодильное'],['мебел','Мебель']],
    arenda:[['земельн','Земельные участки'],['открыт\\S* площадк','Открытые площадки'],['помещени|строени|кабинет','Помещения']]
  };
  Object.values(KIND).forEach(a=>a.forEach(x=>{ x[0] = new RegExp(x[0]); }));
  const OTHER = { nedvizhimost:'Прочая недвижимость', avto:'Прочие марки', gruz:'Прочая грузовая техника', spec:'Прочая спецтехника', oborud:'Прочее оборудование', arenda:'Прочее' };
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
  .bls .bk-kpi{background:#fff;border:1px solid #e4e4e7;border-radius:12px;padding:12px 14px;box-shadow:0 1px 3px rgba(20,30,45,.08)}
  .bls .bk-kpi b{display:block;font-size:24px}
  .bls .bk-kpi span{color:#52525b;font-size:13px}
  .bls .pnl{background:#fff;border:1px solid #e4e4e7;border-radius:12px;padding:16px;box-shadow:0 1px 3px rgba(20,30,45,.08);margin-bottom:16px}
  .bls .pnl h2{font-size:16px;margin:0 0 10px}
  .bls .mut{color:#71717a;font-size:13px}
  .bls .tabs{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:14px}
  .bls .tabs a{padding:6px 12px;border-radius:16px;border:1px solid #d4d4d8;text-decoration:none;color:#18181b;background:#fff;font-size:14px}
  .bls .tabs a.on{background:#f4511e;border-color:#f4511e;color:#fff}
  .bls .g2{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:16px}
  .bls .cols{display:flex;align-items:flex-end;gap:3px;height:190px;padding-top:4px}
  .bls .col{flex:1;min-width:4px;max-width:56px;height:100%;display:flex;flex-direction:column;justify-content:flex-end;text-align:center}
  .bls .col b{font-size:10px;font-weight:600;color:#52525b;min-height:13px;line-height:13px}
  .bls .col .stk{display:flex;flex-direction:column-reverse;border-radius:3px 3px 0 0;overflow:hidden;min-height:0}
  .bls .col .stk i{display:block;min-height:1px}
  .bls .col span{font-size:10px;color:#71717a;height:14px;line-height:14px;margin-top:3px;white-space:nowrap}
  .bls .lg{display:flex;gap:14px;flex-wrap:wrap;margin-top:10px;font-size:12px;color:#52525b}
  .bls .lg i,.bls .dot{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
  .bls .hb-r{display:grid;grid-template-columns:minmax(110px,34%) 1fr auto;gap:10px;align-items:center;padding:4px 0}
  .bls .hb-l{font-size:13px;color:#52525b}
  .bls .hb-t{background:#f4f4f5;border-radius:4px;height:14px;overflow:hidden}
  .bls .hb-t i{display:block;height:100%;border-radius:4px}
  .bls .hb-v{font-size:13px;font-weight:600;white-space:nowrap}
  .bls .hb-v small{font-weight:400;color:#71717a}
  .bls .tw{overflow-x:auto}
  .bls table{border-collapse:collapse;width:100%}
  .bls th,.bls td{text-align:left;padding:7px 8px;border-bottom:1px solid #e4e4e7;vertical-align:top;white-space:nowrap;font-size:14px}
  .bls th{font-weight:600;color:#52525b;font-size:12px;text-transform:uppercase;letter-spacing:.02em}
  .bls td:first-child{white-space:normal;min-width:160px}
  .bls .heat{display:inline-block;min-width:34px;text-align:center;border-radius:4px;padding:1px 6px;font-weight:600}
  .bls .btn2{border:1px solid #d4d4d8;background:#fff;border-radius:6px;padding:7px 12px;cursor:pointer;font:inherit}
  .bls .fbar{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:flex-end;margin:-4px 0 16px}
  .bls .fbar label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#52525b}
  .bls .fbar select{font:inherit;font-size:14px;padding:6px 8px;border:1px solid #d4d4d8;border-radius:6px;background:#fff;color:#18181b;min-width:180px;max-width:280px}
  .bls .fbar .rst{font-size:13px;color:#b3261e;padding-bottom:8px}
  .bls .fnote{background:#fff1ea;border:1px solid #fdc8b0;border-radius:8px;padding:8px 12px;font-size:13px;margin-bottom:14px}
  .bls .sub{display:inline-block;padding-left:18px;color:#52525b}
  .bls .btabs{display:flex;gap:0;flex-wrap:wrap;border-bottom:2px solid #e4e4e7;margin-bottom:14px}
  .bls .btabs a{padding:9px 14px;text-decoration:none;color:#52525b;font-weight:600;font-size:15px;border-bottom:2px solid transparent;margin-bottom:-2px}
  .bls .btabs a.on{color:#f4511e;border-bottom-color:#f4511e}
  .bls .hrow{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;justify-content:space-between;margin-bottom:10px}
  .bls .hrow h2{margin:0}
  .bls .pnl h3{font-size:14px;margin:18px 0 8px}
  .bls .bk-sw{display:inline-flex;background:#f4f4f5;border-radius:8px;padding:3px;gap:2px;flex-wrap:wrap}
  .bls .bk-sw button{border:0;background:none;padding:5px 11px;border-radius:6px;font:inherit;font-size:13px;color:#52525b;cursor:pointer}
  .bls .bk-sw button.on{background:#fff;color:#18181b;font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.12)}
  @media (max-width:860px){ .bls .g2{grid-template-columns:1fr} }
  @media (max-width:600px){ .bls .btabs{flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none} .bls .btabs a{white-space:nowrap;padding:9px 11px;font-size:14px} }
  @media (max-width:600px){ .bls .fbar label{flex:1 1 100%} .bls .fbar select{max-width:none;width:100%} }`;
  function css(){ if(document.getElementById('bls-css')) return; const s = document.createElement('style'); s.id = 'bls-css'; s.textContent = CSS; document.head.appendChild(s); }

  function hbars(rows, unit=''){
    const max = Math.max(1, ...rows.map(r=>r[1]));
    return rows.map(([label, v, note, col])=>`<div class="hb-r"><span class="hb-l">${esc(label)}</span>
      <span class="hb-t"><i style="width:${Math.max(v?2:0, v/max*100)}%;background:${col||'#f4511e'}"></i></span>
      <span class="hb-v">${nf(v)}${unit}${note?` <small>${esc(note)}</small>`:''}</span></div>`).join('');
  }
  function cols(days){
    const max = Math.max(1, ...days.map(d=>d.total)), every = Math.ceil(days.length/15);
    return `<div class="cols">${days.map((d,i)=>`<div class="col" title="${dshort(d.key)}: ${d.total}">
      <b>${d.total||''}</b><div class="stk" style="height:${d.total/max*100}%">${d.parts ? SECS.map(([s])=>d.parts[s]?`<i style="flex:${d.parts[s]};background:${COL[s]}"></i>`:'').join('') : '<i style="flex:1;background:#f4511e"></i>'}</div>
      <span>${i%every===0?dshort(d.key):''}</span></div>`).join('')}</div>`;
  }
  const legend = () => `<div class="lg">${SECS.map(([s,t])=>`<span><i style="background:${COL[s]}"></i>${t}</span>`).join('')}</div>`;
  const tbl = (head, rows) => `<div class="tw"><table><tr>${head.map(h=>`<th>${h}</th>`).join('')}</tr>${rows.map(r=>`<tr>${r.map(c=>`<td>${c}</td>`).join('')}</tr>`).join('')}</table></div>`;
  function daysRange(fromTs){ const out = []; const d = new Date(fromTs*1000); d.setHours(12,0,0,0);
    const end = new Date(); end.setHours(12,0,0,0);
    for(; d <= end; d.setDate(d.getDate()+1)) out.push(dkey(d.getTime()/1000)); return out; }

  // ── вкладки (15.10): блоки по темам вместо одной ленты; считается и рисуется только открытая вкладка ──
  const TABS = [
    ['now', 'Рынок сейчас', ['kpi', 'days', 'cut', 'csv']],
    ['prices', 'Цены', ['prices', 'disc', 'sqm', 'drops']],
    ['sales', 'Итоги и продажи', ['sales', 'months', 'rounds', 'chance', 'csv']],
    ['sellers', 'Продавцы и площадки', ['sellers', 'platstat']],
    ['service', 'Служебное', ['robot', 'search0', 'quality', 'demand']]
  ];
  // старые id блоков (до 15.10) — в новые: сохранённые настройки кабинета продолжают работать
  const OLD = { fresh:'days', size:'days', soon:'days', plat:'cut', sec:'cut', reg:'cut', topdisc:'disc', results:'sales' };
  const FINAL = ['sold', 'single', 'failed', 'cancelled'];
  const ST = { sold:['Продан','#1d7a4d'], single:['Продан единственному участнику','#4cae7d'], failed:['Не состоялись','#d9761f'], cancelled:['Отменены','#9aa3ad'] };
  const MON = ['янв','фев','мар','апр','май','июн','июл','авг','сен','окт','ноя','дек'];

  function render(el, o){
    css();
    const lots = o.lots || [], daily = o.daily || [], site = o.site || '';
    // фильтры: вкладка, период, раздел, площадка, область, город, тип объекта («раздел|тип»)
    const f0 = o.f || { per:o.per, sec:o.sec };
    const f = { tab:f0.tab||'', per:f0.per||'30', sec:f0.sec||'', plat:f0.plat||'', reg:f0.reg||'', city:f0.reg ? f0.city||'' : '', kind:f0.kind||'' };
    const { per, sec, plat, reg, city, kind } = f;
    const on = new Set((o.blocks || BLOCKS.map(b=>b[0])).map(b=>OLD[b] || b).filter(b=>o.admin || !ADMIN_ONLY.includes(b)));
    const tabs = TABS.filter(([, , bs])=>bs.some(b=>on.has(b) && b!=='csv'));
    const tab = (tabs.find(t=>t[0]===f.tab) || tabs[0] || TABS[0])[0];
    const has = b => on.has(b) && TABS.find(t=>t[0]===tab)[2].includes(b);
    const now = Date.now()/1000, from = per==='all' ? 0 : now - (+per)*86400;
    const regOf = l => REG.includes(l.region) ? l.region : 'не указан / другое';
    const regs = [...REG, 'не указан / другое'];
    const kOf = l => l._k || (l._k = (l.section||'') + '|' + kindOf(l));
    const inF = (l, skip) => (!sec || l.section===sec) && (!plat || l.platform===plat) && (!reg || regOf(l)===reg)
      && (skip==='city' || !city || l.city===city) && (skip==='kind' || !kind || kOf(l)===kind);
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
    // переключатель вида внутри блока (график, разрез): все варианты уже нарисованы, кнопка показывает нужный
    const sw = (id, items) => `<div class="bk-sw" data-sw="${id}">${items.map(([k,t],i)=>`<button type="button" data-k="${k}" class="${i?'':'on'}">${t}</button>`).join('')}</div>`;
    const swPane = (id, k, html, first) => `<div data-swp="${id}" data-k="${k}"${first?'':' hidden'}>${html}</div>`;
    const P = [];   // панели по порядку

    // итоги завершённых торгов: таблица sales (копится дольше архива); если её нет — итоги лотов архива
    const allSales = (o.sales && o.sales.length ? o.sales : lots.filter(l=>l.status==='archive' && l.result && FINAL.includes(l.result.st)).map(l=>({
      key:l.id, id:l.id, at:l.result.at || l.closed, platform:l.platform, section:l.section, region:l.region, city:l.city, location:l.location, name:l.name,
      debtor:l.debtor, area_num:l.area_num, url:l.url, st:l.result.st, start:l.result.start, price:l.result.price, bids:l.result.bids, users:l.result.users })))
      .filter(x=>FINAL.includes(x.st));
    const g = { sold:x=>(x.st==='sold' || x.st==='single') && x.price > 0, pm:x=>x.start > 0 && x.price > 0 ? (x.price / x.start - 1) * 100 : null,
                price:x=>+x.price, users:x=>+x.users||0 };
    const HR = ['Завершилось торгов','Продано','Доля продаж','Цена продажи к начальной (медиана)','Цена продажи, BYN (медиана)','Участников (медиана)'];
    const statRow = (label, xs) => { const s = xs.filter(g.sold), p = s.map(g.pm).filter(v=>v!==null), u = xs.map(g.users).filter(v=>v>0);
      return [label, nf(xs.length), nf(s.length), xs.length >= 3 && !s.length ? '<b style="color:#b3261e">0% — не продаётся</b>' : pc(s.length, xs.length), mt(med(p)),
        s.length ? nf(med(s.map(g.price))) : '—', u.length ? nf(med(u)) : '—']; };
    const bySecPlat = xs => { const rows = [];
      secsShown.forEach(([s])=>{ const a = xs.filter(x=>x.section===s); if(!a.length) return;
        rows.push(statRow(`<b>${dotSec(s)}</b>`, a).map((c,i)=>i ? `<b>${c}</b>` : c));
        platsShown.forEach(p=>{ const b = a.filter(x=>x.platform===p); if(b.length) rows.push(statRow(`<span class="sub">${esc(p)}</span>`, b)); }); });
      return rows; };
    const byKindRows = xs => Object.entries(xs.reduce((m,x)=>{ (m[kOf(x)] ||= []).push(x); return m; }, {}))
      .sort((a,b)=>b[1].filter(g.sold).length - a[1].filter(g.sold).length || b[1].length - a[1].length).slice(0,30)
      .map(([k,a])=>statRow(esc(k.split('|')[1]) + (sec ? '' : ` <small class="mut">${esc(SEC_RU[k.split('|')[0]]||'')}</small>`), a));
    const BF = '<p class="mut">Торги с октября 2025 года загружены из архивов площадок (konfiskat.by — с июля 2026, auction24.by хранит их только с апреля 2026, belauction.by открыт роботам примерно на месяц назад, «Оборудование» — за месяц; butb.by и lotsale.by подключены 09.10.2026); с 25.09.2026 робот собирает итоги сам после даты торгов.</p>';
    const S = allSales.filter(x=>inF(x) && x.at >= from);          // за период
    const SA = allSales.filter(x=>inF(x));                          // за всё время — для помесячной динамики и кругов
    const catNote = one ? '' : '<p class="mut">Цены и проценты разных категорий несравнимы — выберите раздел или тип объекта, и появятся медианы по категории.</p>';
    // города внутри области (или самые крупные по всей стране) — для разрезов и цены м²
    const cityRows = (xs, n) => Object.entries(xs.reduce((m,l)=>{ const c = l.city || ''; if(c && !/^Остальн/.test(c)) (m[c] ||= []).push(l); return m; }, {}))
      .sort((a,b)=>b[1].length-a[1].length).slice(0, n);

    // ══ Рынок сейчас ══
    if(has('days')){
      const startTs = per==='all' ? (isFinite(seenFrom) ? seenFrom : now) : Math.max(from, isFinite(seenFrom) ? seenFrom : from);
      const byDay = {}; fresh.forEach(l=>{ const k = dkey(l.first_seen); const d = byDay[k] ||= { total:0, parts:{} }; d.total++; d.parts[l.section] = (d.parts[l.section]||0) + 1; });
      const nd = daysRange(startTs).map(k=>({ key:k, total:(byDay[k]||{}).total||0, parts:(byDay[k]||{}).parts }));
      let dyn, note = '';
      if(!plat && !reg && !kind){
        const dl = daily.filter(d=>per==='all' || new Date(d.day).getTime()/1000 >= from - 86400);
        dyn = dl.map(d=>{ const st = d.stats||{}; return { key:d.day, total: sec ? ((st.by_section||{})[sec]||0) : st.active||0, parts: sec ? null : st.by_section }; });
      } else {
        // под площадку, область или тип снимков дня нет — восстанавливаем по лотам: на рынке с появления до закрытия приёма заявок
        const pool = lots.filter(l=>l.first_seen && !['dup','hidden'].includes(l.hidden_why) && inF(l));
        dyn = daysRange(startTs).map(k=>{ const end = new Date(k + 'T23:59:59').getTime()/1000, parts = {};
          const xs = pool.filter(l=>l.first_seen<=end && (l.status==='active' || (l.closed||0) > end)); xs.forEach(l=>parts[l.section] = (parts[l.section]||0) + 1);
          return { key:k, total:xs.length, parts: sec ? null : parts }; });
        note = '<p class="mut">С фильтром по площадке, области или типу — по лотам, которые робот видел на рынке.</p>';
      }
      const soon = {}; onSite.forEach(l=>{ if(l.req_to>now && l.req_to<now+14*86400){ const k = dkey(l.req_to); const d = soon[k] ||= { total:0, parts:{} }; d.total++; d.parts[l.section] = (d.parts[l.section]||0)+1; } });
      const sd = []; for(let i=0;i<14;i++){ const k = dkey(now + i*86400); sd.push({ key:k, total:(soon[k]||{}).total||0, parts:(soon[k]||{}).parts }); }
      P.push(`<div class="pnl"><div class="hrow"><h2>По дням</h2>${sw('days', [['new','Новые лоты'],['size','Размер рынка'],['soon','Закрытие заявок, 14 дней']])}</div>
        ${swPane('days','new', nd.length ? cols(nd) + legend() : '<p class="mut">Нет данных.</p>', true)}
        ${swPane('days','size', dyn.length>=2 ? cols(dyn) + (sec?'':legend()) + note : `<p class="mut">Снимок рынка сохраняется раз в день; график появится со второго дня.</p>`)}
        ${swPane('days','soon', cols(sd) + legend() + '<p class="mut">Сколько лотов на сайте закрывают приём заявок в каждый из ближайших 14 дней.</p>')}</div>`);
    }
    if(has('cut')){
      const secT = tbl(['Раздел','На рынке','Новых','Закрылось','Сумма, BYN','Медиана, BYN','Мин.','Макс.','Скидка к рынку'], secsShown.map(([s])=>{
        const m = market.filter(l=>l.section===s), pr = m.map(l=>+l.price).filter(x=>x>0), ds = m.map(disc).filter(x=>x!==null);
        return [dotSec(s), nf(m.length), nf(fresh.filter(l=>l.section===s).length), nf(done.filter(l=>l.section===s).length),
          big(val(m)), nf(med(pr)), pr.length?nf(Math.min(...pr)):'—', pr.length?big(Math.max(...pr)):'—', ds.length?Math.round(med(ds))+'%':'—']; }));
      const cell = {}; market.forEach(l=>{ const k = regOf(l)+'|'+l.section; cell[k] = (cell[k]||0)+1; });
      const cmax = Math.max(1, ...Object.values(cell));
      const regT = tbl(['Регион', ...secsShown.map(([,t])=>t), 'Всего', 'Сумма, BYN'], regs.map(r=>{ const tot = market.filter(l=>regOf(l)===r).length; if(!tot) return null;
        return [esc(r), ...secsShown.map(([s])=>{ const v = cell[r+'|'+s]||0; return v ? `<span class="heat" style="background:rgba(18,80,143,${(0.08+0.6*v/cmax).toFixed(2)})">${v}</span>` : '<span class="mut">·</span>'; }),
          `<b>${nf(tot)}</b>`, big(val(market.filter(l=>regOf(l)===r)))]; }).filter(Boolean));
      const cr = cityRows(market, reg ? 40 : 25);
      const cityT = cr.length ? tbl(['Город / район', ...secsShown.map(([,t])=>t), 'Всего', 'Новых', one ? 'Медиана, BYN' : 'Сумма, BYN'], cr.map(([c,a])=>[esc(c),
          ...secsShown.map(([s])=>{ const v = a.filter(l=>l.section===s).length; return v ? nf(v) : '<span class="mut">·</span>'; }), `<b>${nf(a.length)}</b>`,
          nf(fresh.filter(l=>l.city===c).length), one ? nf(med(a.map(l=>+l.price).filter(x=>x>0))) : big(val(a))]))
        + `<p class="mut">${reg ? 'Города и районы области' : 'Крупнейшие города и районы страны; выберите область — появятся все её города и районы'}.</p>` : '<p class="mut">Нет данных о городах.</p>';
      P.push(`<div class="pnl"><div class="hrow"><h2>Из чего состоит рынок</h2>${sw('cut', [['sec','Разделы'],['reg','Регионы'],['city','Города и районы']])}</div>
        ${swPane('cut','sec', secT, true)}${swPane('cut','reg', regT)}${swPane('cut','city', cityT)}</div>`);
    }

    // ══ Цены ══
    if(has('prices')){
      const B = [[0,5e3,'до 5 тыс.'],[5e3,2e4,'5–20 тыс.'],[2e4,5e4,'20–50 тыс.'],[5e4,1e5,'50–100 тыс.'],[1e5,5e5,'100–500 тыс.'],[5e5,Infinity,'от 500 тыс.']];
      P.push(`<div class="pnl"><h2>Стартовые цены лотов на рынке</h2>${hbars(B.map(([a,b,t])=>{ const n = market.filter(l=>l.price>=a && l.price<b).length; return [t+' BYN', n, pc(n, market.length)]; }))}</div>`);
    }
    if(has('disc')){
      const D = [[-1e9,0,'дороже рынка'],[0,20,'дешевле на 0–20%'],[20,40,'на 20–40%'],[40,60,'на 40–60%'],[60,1e9,'на 60% и больше']];
      const top = market.filter(l=>disc(l)!==null).sort((a,b)=>disc(b)-disc(a)).slice(0,10);
      P.push(`<div class="pnl"><h2>Скидка к рынку</h2>${discs.length ? `<p style="margin-top:0">Медианная скидка — <b>${Math.round(med(discs))}%</b> по ${nf(discs.length)} ${plural(discs.length,'лоту','лотам','лотам')} с рыночным ориентиром.</p>`
          + hbars(D.map(([a,b,t],i)=>[t, discs.filter(d=>d>=a && d<b).length, '', i===0?'#b3261e':i>=3?'#1d7a4d':'#12508f']))
          + (top.length ? `<h3>Самая большая скидка</h3>` + tbl(['Лот','Раздел','Площадка','Цена, BYN','Рынок, BYN','Скидка'], top.map(l=>[link(l), esc(SEC_RU[l.section]||''), esc(l.platform), nf(l.price), nf(l.market.median), `<b>${disc(l)}%</b>`])) : '')
        : '<p class="mut">Нет лотов с ориентиром.</p>'}
        <p class="mut">По лотам, у которых нашёлся рыночный ориентир на Kufar. Большая скидка бывает и ошибкой сравнения: сравниваются обычные объявления, состояние объекта не учитывается.</p></div>`);
    }
    if(has('sqm') && (!sec || sec==='nedvizhimost')){
      const realty = market.filter(l=>l.section==='nedvizhimost' && +l.area_num>0 && +l.area_num<=1000 && +l.price>0);
      const rowsOf = groups => groups.map(([t, a])=>{ const v = a.map(l=>l.price/l.area_num); return v.length ? [t, Math.round(med(v)), `${v.length} ${plural(v.length,'объект','объекта','объектов')}`] : null; }).filter(Boolean).sort((a,b)=>b[1]-a[1]);
      const byReg = rowsOf(regs.map(r=>[r, realty.filter(l=>regOf(l)===r)]));
      const byCity = rowsOf(cityRows(realty, reg ? 40 : 15));
      P.push(`<div class="pnl"><div class="hrow"><h2>Недвижимость: медианная цена м²</h2>${sw('sqm', reg ? [['city','Города и районы'],['reg','Области']] : [['reg','Области'],['city','Города и районы']])}</div>
        ${swPane('sqm', reg ? 'city' : 'reg', (reg ? byCity : byReg).length ? hbars(reg ? byCity : byReg, ' BYN') : '<p class="mut">Нет лотов с указанной площадью.</p>', true)}
        ${swPane('sqm', reg ? 'reg' : 'city', (reg ? byReg : byCity).length ? hbars(reg ? byReg : byCity, ' BYN') : '<p class="mut">Нет лотов с указанной площадью.</p>')}
        <p class="mut">Стартовая цена, делённая на площадь. Объекты до 1 000 м² — квартиры, дома, помещения; комплексы и заводы не учитываются.</p></div>`);
    }
    if(has('drops')){
      const drops = market.filter(l=>+l.price0>0 && +l.price<+l.price0).map(l=>[l, Math.round((l.price0-l.price)/l.price0*100)]).sort((a,b)=>b[1]-a[1]);
      P.push(`<div class="pnl"><h2>Снижение цены (повторные торги)</h2>${drops.length?`<p style="margin-top:0">${nf(drops.length)} ${plural(drops.length,'лот подешевел','лота подешевели','лотов подешевели')} с момента появления, медиана снижения — ${Math.round(med(drops.map(x=>x[1])))}%.</p>`
        + tbl(['Лот','Раздел','Площадка','Было, BYN','Стало, BYN','Снижение'], drops.slice(0,10).map(([l,d])=>[link(l), esc(SEC_RU[l.section]||''), esc(l.platform), nf(l.price0), nf(l.price), `<b>−${d}%</b>`]))
        : '<p class="mut">Пока ни один лот не подешевел — история цен копится с 24.09.2026.</p>'}</div>`);
    }

    // ══ Итоги и продажи ══
    if(has('sales')){
      if(!S.length){
        P.push(`<div class="pnl"><h2>Итоги торгов</h2><p class="mut">За выбранный период и фильтры итогов нет.</p>${BF}</div>`);
      } else {
        const sold = S.filter(g.sold), pms = sold.map(g.pm).filter(v=>v!==null), sum = sold.reduce((a,x)=>a+ +x.price,0);
        const B = [[-1e9,-0.5,'Дешевле начальной','#d9761f'],[-0.5,0.5,'По начальной цене','#7b8794'],[0.5,5.5,'До +5%','#8fbfa6'],[5.5,20,'+5…20%','#4cae7d'],
                   [20,50,'+20…50%','#2f9464'],[50,100,'+50…100%','#1d7a4d'],[100,1e9,'Больше +100%','#145c39']];
        const inB = (v, [a,b]) => v >= a && v < b;
        const distr = one ? (pms.length ? hbars(B.map(bk=>{ const n = pms.filter(v=>inB(v, bk)).length; return [bk[2], n, pc(n, pms.length), bk[3]]; })) : '<p class="mut">Продаж пока нет.</p>')
          : tbl(['Раздел', ...B.map(bk=>bk[2]), 'Медиана'], secsShown.map(([s])=>{ const v = sold.filter(x=>x.section===s).map(g.pm).filter(x=>x!==null); if(!v.length) return null;
              return [dotSec(s), ...B.map(bk=>{ const n = v.filter(x=>inB(x, bk)).length; return n ? `${n} <small class="mut">${pc(n, v.length)}</small>` : '<span class="mut">·</span>'; }), `<b>${mt(med(v))}</b>`]; }).filter(Boolean));
        // где продаётся: области, а при выбранной области — её города и районы
        const placeRows = reg ? cityRows(S, 40) : regs.map(r=>{ const a = S.filter(x=>regOf(x)===r); return a.length ? [r, a] : null; }).filter(Boolean).sort((a,b)=>b[1].length-a[1].length);
        const placeTbl = one ? tbl([reg ? 'Город / район' : 'Регион', ...HR], placeRows.map(([r,a])=>statRow(esc(r), a)))
          : tbl([reg ? 'Город / район' : 'Регион', ...secsShown.map(([,t])=>t), 'Всего'], placeRows.map(([r,a])=>[esc(r), ...secsShown.map(([s])=>{ const b = a.filter(x=>x.section===s); if(!b.length) return '<span class="mut">·</span>';
              const n = b.filter(g.sold).length, sh = n / b.length; return `<span class="heat" style="background:${b.length >= 3 && !n ? 'rgba(179,38,30,.18)' : `rgba(29,122,77,${(0.08+0.55*sh).toFixed(2)})`}" title="продано ${n} из ${b.length}">${n}/${b.length}</span>`; }),
              `${a.filter(g.sold).length}/${a.length} <small class="mut">${pc(a.filter(g.sold).length, a.length)}</small>`]));
        const UB = [[1,1,'1 участник'],[2,2,'2 участника'],[3,5,'3–5 участников'],[6,1e9,'6 и больше']];
        const compRows = xs => UB.map(([a,b,t])=>{ const s = xs.filter(x=>x.users >= a && x.users <= b), p = s.map(g.pm).filter(v=>v!==null);
          return s.length ? [t, nf(s.length), mt(med(p)), nf(med(s.map(x=>+x.bids||0)))] : null; }).filter(Boolean);
        const comp = one ? compRows(sold) : secsShown.flatMap(([s])=>{ const r = compRows(sold.filter(x=>x.section===s)); return r.length ? [[`<b>${dotSec(s)}</b>`,'','',''], ...r.map(x=>[`<span class="sub">${x[0]}</span>`, ...x.slice(1)])] : []; });
        const byKind = Object.entries(S.reduce((m,x)=>{ (m[kOf(x)] ||= []).push(x); return m; }, {}));
        const dead = [...byKind.filter(([,xs])=>xs.length >= 3 && !xs.some(g.sold)).map(([k,xs])=>k.split('|')[1] + (sec ? '' : ` (${SEC_RU[k.split('|')[0]]||''})`) + ' · ' + xs.length),
                      ...(one ? placeRows.filter(([,xs])=>xs.length >= 3 && !xs.some(g.sold)).map(([r,xs])=>r + ' · ' + xs.length) : [])];
        const topP = [...sold].sort((a,b)=>b.price-a.price).slice(0,10), topR = sold.filter(x=>g.pm(x)!==null).sort((a,b)=>g.pm(b)-g.pm(a)).slice(0,10);
        const below = sold.filter(x=>g.pm(x)!==null && g.pm(x) < -0.5).sort((a,b)=>g.pm(a)-g.pm(b)).slice(0,10);
        const lt = xs => tbl(['Лот','Раздел','Площадка','Регион','Начальная, BYN','Продан за, BYN','К начальной','Участников'],
          xs.map(x=>[link(x), esc(SEC_RU[x.section]||''), esc(x.platform), esc(x.region||'—'), nf(x.start), `<b>${nf(x.price)}</b>`, mt(g.pm(x)), x.users || '—']));
        P.push(`<div class="pnl"><h2>Итоги торгов за ${perTxt}</h2>
          <div class="bk-kpis">
            <div class="bk-kpi"><b>${nf(S.length)}</b><span>торгов завершилось</span></div>
            <div class="bk-kpi"><b>${nf(sold.length)}</b><span>продано — ${pc(sold.length, S.length)}</span></div>
            <div class="bk-kpi"><b>${big(sum)}</b><span>BYN — сумма продаж</span></div>
            ${one ? `<div class="bk-kpi"><b>${mt(med(pms))}</b><span>медиана цены продажи к начальной</span></div>
            <div class="bk-kpi"><b>${pc(pms.filter(v=>v > 0.5).length, pms.length)}</b><span>продано дороже начальной</span></div>
            <div class="bk-kpi"><b>${pc(pms.filter(v=>v < -0.5).length, pms.length)}</b><span>продано дешевле начальной</span></div>` : ''}
          </div>
          <h3>Чем закончились торги</h3>${hbars(Object.entries(ST).map(([k,[t,c]])=>{ const n = S.filter(x=>x.st===k).length; return [t, n, pc(n, S.length), c]; }))}
          ${one ? `<h3>Площадки</h3>${tbl(['Площадка', ...HR], platsShown.map(p=>[p, S.filter(x=>x.platform===p)]).filter(([,a])=>a.length).map(([p,a])=>statRow(esc(p), a)))}`
            : `<h3>По разделам и площадкам</h3>${tbl(['Раздел / площадка', ...HR], bySecPlat(S))}${catNote}`}
          <h3>Цена продажи относительно начальной</h3>${distr}
          <h3>${reg ? 'Где продаётся: города и районы' : 'Регионы: где продаётся'}</h3>${placeTbl}${one ? '' : '<p class="mut">В ячейке — продано / завершилось торгов. Красным — три и больше торгов без продаж.</p>'}
          <h3>Какие объекты продаются</h3>${tbl(['Тип объекта', ...HR], byKindRows(S))}
          <p class="mut">Тип определяется по названию лота, у легковых — марка.</p>
          ${comp.length ? `<h3>Конкуренция: чем больше участников, тем дороже</h3>${tbl(['Участников','Продано','Цена продажи к начальной (медиана)','Ставок (медиана)'], comp)}` : ''}
          ${dead.length ? `<h3>Не продаётся</h3><p style="margin-top:0">Три и больше завершённых торгов — и ни одной продажи: ${dead.map(esc).join(' · ')}</p>` : ''}
          ${topP.length ? `<h3>Самые дорогие продажи</h3>${lt(topP)}` : ''}
          ${topR.length ? `<h3>Самый большой рост цены</h3>${lt(topR)}` : ''}
          ${below.length ? `<h3>Проданы дешевле начальной</h3><p class="mut" style="margin-top:0">Торги на понижение и повторные торги со сниженной ценой.</p>${lt(below)}` : ''}
          ${BF}
        </div>`);
      }
    }
    if(has('months')){
      const byM = {}; SA.forEach(x=>{ const d = new Date(x.at*1000), k = `${d.getFullYear()}-${p2(d.getMonth()+1)}`; (byM[k] ||= []).push(x); });
      const ks = Object.keys(byM).sort().slice(-13);
      const sqmOf = xs => { const v = xs.filter(x=>g.sold(x) && x.section==='nedvizhimost' && +x.area_num>0 && +x.area_num<=1000).map(x=>x.price/x.area_num); return v.length >= 3 ? nf(med(v)) : '—'; };
      const mrows = ks.map(k=>{ const a = byM[k], s = a.filter(g.sold), p = s.map(g.pm).filter(v=>v!==null);
        return [`${MON[+k.slice(5)-1]} ${k.slice(0,4)}`, nf(a.length), nf(s.length), pc(s.length, a.length), one ? mt(med(p)) : '—', (!sec || sec==='nedvizhimost') ? sqmOf(a) : '—']; });
      const bars = ks.map(k=>{ const parts = {}; byM[k].filter(g.sold).forEach(x=>parts[x.section] = (parts[x.section]||0) + 1); return { key:k + '-01', total:byM[k].filter(g.sold).length, parts }; });
      P.push(`<div class="pnl"><h2>Продажи по месяцам</h2>${ks.length ? `<p class="mut" style="margin-top:0">Продано лотов в месяц; за всё время наблюдений, без учёта выбранного периода.</p>
          ${cols(bars).replace(/<span>(\d\d)\.(\d\d)<\/span>/g, (m, d, mo)=>`<span>${MON[+mo-1]}</span>`)}${legend()}
          ${tbl(['Месяц','Завершилось','Продано','Доля продаж','Цена продажи к начальной (медиана)','Цена м² при продаже, BYN (медиана)'], mrows.reverse())}${catNote}
          <p class="mut">Цена м² — по проданной недвижимости до 1 000 м², если продаж за месяц хотя бы три. Первые месяцы неполные: архивы площадок загружены не с одной даты. Текущий месяц тоже: итоги последних торгов ещё публикуются, поэтому доля продаж в нём ниже.</p>`
        : '<p class="mut">Нет данных.</p>'}</div>`);
    }
    if(has('rounds')){
      const R = SA.filter(x=>x.rnd > 0);
      const RB = [[1,'1-й круг'],[2,'2-й круг'],[3,'3-й круг'],[4,'4-й и дальше']];
      const rr = RB.map(([n,t])=>{ const a = R.filter(x=>n < 4 ? x.rnd===n : x.rnd>=4); if(!a.length) return null;
        const s = a.filter(g.sold), p = s.map(g.pm).filter(v=>v!==null), dr = a.filter(x=>x.rnd>1 && x.s1>0 && x.start>0).map(x=>(x.start/x.s1 - 1)*100);
        return [t, nf(a.length), nf(s.length), pc(s.length, a.length), n===1 ? '—' : mt(med(dr)), one ? mt(med(p)) : '—', s.length ? nf(med(s.map(g.price))) : '—']; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Повторные торги: брать сейчас или ждать снижения</h2>${rr.length ? `<p class="mut" style="margin-top:0">Торги одного и того же объекта по порядку: робот узнаёт объект по VIN, инвентарному или кадастровому номеру, у недвижимости — ещё по названию и адресу. За всё время наблюдений.</p>
          ${tbl(['Круг','Завершилось торгов','Продано','Доля продаж','Начальная цена к 1-му кругу (медиана)','Цена продажи к начальной (медиана)','Цена продажи, BYN (медиана)'], rr)}${catNote}
          <p class="mut">«1-й круг» — первые торги объекта, которые мы видели: учёт ведётся с октября 2025 года, часть объектов могла выставляться и раньше.</p>`
        : '<p class="mut">Пока нет данных о кругах торгов — они появятся после ближайшего обновления сайта.</p>'}</div>`);
    }
    if(has('chance')){
      const B = [[0,5e3,'до 5 тыс.'],[5e3,2e4,'5–20 тыс.'],[2e4,5e4,'20–50 тыс.'],[5e4,1e5,'50–100 тыс.'],[1e5,5e5,'100–500 тыс.'],[5e5,Infinity,'от 500 тыс.']];
      const cr = B.map(([a,b,t])=>{ const xs = S.filter(x=>x.start>=a && x.start<b); return xs.length ? statRow(t+' BYN', xs) : null; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Шанс продажи по стартовой цене</h2>${cr.length ? tbl(['Стартовая цена', ...HR], cr) + catNote : '<p class="mut">За выбранный период и фильтры итогов нет.</p>'}
        <p class="mut">Какая доля торгов в каждом ценовом диапазоне заканчивается продажей — за ${perTxt}.</p></div>`);
    }

    // ══ Продавцы и площадки ══
    if(has('sellers')){
      const sl = {}; market.forEach(l=>{ const d = (l.debtor||'').trim(); if(!d || /^(Конфискованное имущество|Физическое лицо)$/.test(d)) return; const x = sl[d] ||= { n:0, v:0 }; x.n++; x.v += +l.price||0; });
      const top = Object.entries(sl).sort((a,b)=>b[1].n-a[1].n).slice(0,15);
      P.push(`<div class="pnl"><h2>Крупнейшие продавцы</h2><p class="mut" style="margin-top:0">По числу лотов на рынке; конфискат и физлица не в счёт.</p>
        ${top.length?tbl(['Должник / продавец','Лотов','Сумма, BYN'], top.map(([d,x])=>[esc(d.slice(0,80)), nf(x.n), big(x.v)])):'<p class="mut">Нет данных.</p>'}</div>`);
    }
    if(has('platstat')){
      const win = xs => { const w = med(xs.filter(l=>l.req_to>l.first_seen).map(l=>(l.req_to-l.first_seen)/86400)); return w!=null ? Math.round(w)+' дн.' : '—'; };
      const rows = platsShown.map(p=>{ const m = market.filter(l=>l.platform===p), f2 = fresh.filter(l=>l.platform===p), s = onSite.filter(l=>l.platform===p), sa = S.filter(x=>x.platform===p);
        if(!m.length && !f2.length && !sa.length) return null;
        const merged = lots.filter(l=>l.platform===p && l.status==='active' && l.hidden_why==='dup' && inF(l)).length, sold = sa.filter(g.sold);
        return [esc(p), nf(s.length), nf(m.length) + (merged?` <small class="mut">+${merged} дубл.</small>`:''), pc(m.length, market.length), nf(f2.length),
          one ? nf(med(m.map(l=>+l.price).filter(x=>x>0))) : big(val(m)), m.length ? win(f2) : '—', nf(sa.length), sa.length ? pc(sold.length, sa.length) : '—', one ? mt(med(sold.map(g.pm).filter(v=>v!==null))) : '—']; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Площадки</h2>${rows.length ? tbl(['Площадка','На сайте','На рынке','Доля','Новых за период', one ? 'Медианная цена, BYN' : 'Сумма стартовых цен, BYN','Окно подачи заявок','Завершилось торгов','Доля продаж','Цена продажи к начальной'], rows) : '<p class="mut">Нет лотов.</p>'}
        <p class="mut">Окно подачи заявок — медиана дней от появления лота до конца приёма заявок. «Дубл.» — лоты, склеенные с карточкой другой площадки. Торги и продажи — за ${perTxt}.</p>${catNote}</div>`);
    }

    // ══ Служебное (админка) ══
    if(has('robot')){
      const runs = o.runs || [];
      const rows = PLATS.map(p=>{
        const okRun = runs.find(r=>!(r.unread||[]).some(u=>String(u).startsWith(p + ' ')));
        const lastSale = Math.max(0, ...allSales.filter(x=>x.platform===p && +x.at <= now).map(x=>+x.at||0));   // отменённые торги бывают с датой в будущем
        const wait = lots.filter(l=>l.platform===p && l.status==='archive' && l.why==='deadline' && l.closed < now - 3*86400 && l.closed > now - 120*86400 && !(l.result && FINAL.includes(l.result.st)));
        const oldest = wait.length ? Math.round((now - Math.min(...wait.map(l=>l.closed)))/86400) : 0;
        const offline = p==='mgcn.by';
        return [esc(p), nf(lots.filter(l=>l.platform===p && l.status==='active').length), okRun ? dt(new Date(okRun.at).getTime()/1000) + (runs[0] && okRun !== runs[0] ? ' <b style="color:#b3261e">сбой в последних обходах</b>' : '') : (runs.length ? '<b style="color:#b3261e">не читается</b>' : '—'),
          lastSale ? dt(lastSale) + ` <small class="mut">${Math.round((now-lastSale)/86400)} дн. назад</small>` : '—',
          offline ? '<span class="mut">итоги онлайн не публикуются</span>' : wait.length ? `${nf(wait.length)} <small class="mut">старейший — ${oldest} дн.</small>` : '0'];
      });
      P.push(`<div class="pnl"><h2>Обход площадок и итоги торгов</h2>${tbl(['Площадка','Лотов на рынке','Последний обход без сбоев','Последний итог торгов','Ждут итогов дольше 3 дней'], rows)}
        <p class="mut">«Ждут итогов» — торги прошли больше трёх дней назад (но не раньше 4 месяцев), а итог не опубликован или робот его не нашёл.</p></div>`);
    }
    if(has('search0')){
      const ms = (o.misses || []).slice().sort((a,b)=>b.n-a.n || String(b.last_at).localeCompare(String(a.last_at))).slice(0,50);
      P.push(`<div class="pnl"><h2>Поиски без результатов</h2>${ms.length ? tbl(['Что искали','Сколько раз','Последний раз'], ms.map(m=>[esc(m.q), nf(m.n), dt(new Date(m.last_at).getTime()/1000)]))
        : '<p class="mut">Пока пусто: сюда попадают запросы в поиске по каталогу, по которым среди активных лотов ничего не нашлось.</p>'}
        <p class="mut">Список того, что чинить в поиске: синонимы, опечатки, названия марок. Хранится 90 дней.</p></div>`);
    }
    if(has('quality')){
      const rows = platsShown.map(p=>{ const m = market.filter(l=>l.platform===p); if(!m.length) return null;
        return [esc(p), nf(m.length), pc(m.filter(l=>!l.photo).length, m.length), pc(m.filter(l=>!(+l.price>0)).length, m.length),
          pc(m.filter(l=>!(l.location||'').trim()).length, m.length), pc(m.filter(l=>(l.reasons||[]).includes('rule_deadline')).length, m.length), pc(m.filter(l=>l.market).length, m.length)]; }).filter(Boolean);
      P.push(`<div class="pnl"><h2>Качество данных площадок</h2>${tbl(['Площадка','Лотов','Без фото','Без цены','Без города','Срок по правилу','С ориентиром'], rows)}</div>`);
    }
    if(has('demand') && (o.leads || o.bots)){
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
    const H = ch => href(Object.assign({}, f, { tab }, ch));
    const kc = {}; lots.forEach(l=>{ if(l.hidden_why!=='dup' && inF(l, 'kind')) kc[kOf(l)] = (kc[kOf(l)]||0) + 1; });
    const kindOpts = SECS.filter(([s])=>!sec || s===sec).map(([s,t])=>{ const ks = Object.entries(kc).filter(([k])=>k.startsWith(s+'|')).sort((a,b)=>b[1]-a[1]);
      if(!ks.length) return '';
      const opts = ks.map(([k,n])=>`<option value="${esc(k)}"${k===kind?' selected':''}>${esc(k.split('|')[1])} (${n})</option>`).join('');
      return sec ? opts : `<optgroup label="${esc(t)}">${opts}</optgroup>`; }).join('');
    // города и районы выбранной области — из лотов с остальными фильтрами
    const cc = {}; if(reg) lots.forEach(l=>{ if(l.city && l.hidden_why!=='dup' && inF(l, 'city')) cc[l.city] = (cc[l.city]||0) + 1; });
    const cityOpts = Object.entries(cc).sort((a,b)=>a[0].localeCompare(b[0], 'ru')).map(([c,n])=>`<option value="${esc(c)}"${c===city?' selected':''}>${esc(c)} (${n})</option>`).join('');
    const sel = (key, label, first, opts) => `<label>${label}<select data-f="${key}"><option value="">${first}</option>${opts}</select></label>`;
    const active = [plat, reg, city, kind ? kind.split('|')[1] : ''].filter(Boolean);
    const go = (ch, a) => `href="${H(ch)}" data-go='${esc(JSON.stringify(ch))}'${a ? ` class="${a}"` : ''}`;
    const bar = `<div class="btabs">${tabs.map(([k,t])=>`<a ${go({ tab:k }, k===tab?'on':'')}>${t}</a>`).join('')}</div>
      <div class="tabs">${[['7','7 дней'],['30','30 дней'],['90','90 дней'],['all','Всё время']].map(([k,t])=>`<a ${go({ per:k }, k===per?'on':'')}>${t}</a>`).join('')}
        <span style="width:12px"></span><a ${go({ sec:'', kind:'' }, !sec?'on':'')}>Все разделы</a>${SECS.map(([k,t])=>`<a ${go({ sec:k, kind: kind.startsWith(k+'|') ? kind : '' }, k===sec?'on':'')}>${t}</a>`).join('')}</div>
      <div class="fbar">
        ${sel('plat', 'Площадка', 'Все площадки', PLATS.map(p=>`<option${p===plat?' selected':''}>${esc(p)}</option>`).join(''))}
        ${sel('reg', 'Область', 'Все области', regs.map(r=>`<option${r===reg?' selected':''}>${esc(r)}</option>`).join(''))}
        ${reg ? sel('city', 'Город / район', 'Вся область', cityOpts) : ''}
        ${sel('kind', 'Тип объекта', sec ? 'Все типы раздела' : 'Все типы', kindOpts)}
        ${active.length ? `<a class="rst" ${go({ plat:'', reg:'', city:'', kind:'' })}>Сбросить фильтры</a>` : ''}
      </div>
      ${active.length ? `<div class="fnote">Показано: ${esc([sec ? SEC_RU[sec] : 'все разделы', ...active].join(' · '))} · ${perTxt}</div>` : ''}`;
    const csvBtn = tab==='now' ? `<p><button class="btn2" type="button" data-bls-csv="market">Выгрузить рынок в Excel (CSV)</button> <span class="mut">${nf(market.length)} лотов с текущими фильтрами</span></p>`
      : tab==='sales' ? `<p><button class="btn2" type="button" data-bls-csv="sales">Выгрузить итоги торгов в Excel (CSV)</button> <span class="mut">${nf(S.length)} торгов за ${perTxt} с текущими фильтрами</span></p>` : '';
    el.innerHTML = `<div class="bls">
      ${bar}
      ${has('kpi')?`<div class="bk-kpis">
        <div class="bk-kpi"><b>${nf(market.length)}</b><span>лотов на рынке сейчас${o.admin?` (на сайте ${nf(onSite.length)})`:''}</span></div>
        <div class="bk-kpi"><b>${nf(fresh.length)}</b><span>новых за ${perTxt}</span></div>
        <div class="bk-kpi"><b>${nf(done.filter(l=>l.why==='deadline').length)}</b><span>закрыт приём заявок за ${perTxt}</span></div>
        <div class="bk-kpi"><b>${nf(done.filter(l=>l.why==='removed').length)}</b><span>снято площадками досрочно</span></div>
        <div class="bk-kpi"><b>${big(val(market))}</b><span>BYN — сумма стартовых цен на рынке</span></div>
        <div class="bk-kpi"><b>${discs.length?Math.round(med(discs))+'%':'—'}</b><span>медианная скидка к рынку (${nf(discs.length)} ${plural(discs.length,'лот','лота','лотов')} с ориентиром)</span></div>
      </div>`:''}
      ${P.join('') || '<p class="mut">На этой вкладке нет включённых блоков.</p>'}
      ${has('csv') ? csvBtn : ''}
      <p class="mut">Рынок — активные лоты всех площадок без дублей. Учёт новых лотов ведётся с ${isFinite(seenFrom)?dt(seenFrom):'—'}; лоты, загруженные из архивов площадок, в новые не входят.</p>
    </div>`;
    // переходы внутри аналитики — без перезагрузки страницы: перерисовываем, адрес обновляем
    const redraw = ch => { const nf2 = Object.assign({}, f, { tab }, ch), y = window.scrollY;
      try{ history.replaceState(null, '', href(nf2)); }catch(e){}
      render(el, Object.assign({}, o, { f:nf2 })); if(!('tab' in ch)) window.scrollTo(0, y); };
    el.querySelectorAll('a[data-go]').forEach(a=>a.onclick = e => { if(e.metaKey || e.ctrlKey || e.shiftKey) return; e.preventDefault(); redraw(JSON.parse(a.dataset.go)); });
    el.querySelectorAll('select[data-f]').forEach(s=>s.onchange = () => {
      const ch = { [s.dataset.f]: s.value };
      if(s.dataset.f==='reg') ch.city = '';
      redraw(ch);
    });
    el.querySelectorAll('[data-sw]').forEach(box=>box.querySelectorAll('button').forEach(b=>b.onclick = () => {
      box.querySelectorAll('button').forEach(x=>x.classList.toggle('on', x===b));
      el.querySelectorAll(`[data-swp="${box.dataset.sw}"]`).forEach(p=>{ p.hidden = p.dataset.k !== b.dataset.k; });
    }));
    const cv = v => { const s = String(v==null?'':v); return /[;"\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s; };
    const save = (name, C, rows) => {
      const csv = '﻿' + [C.map(c=>c[0]).join(';'), ...rows.map(l=>C.map(([,fn])=>cv(typeof fn==='function'?fn(l):l[fn])).join(';'))].join('\r\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type:'text/csv;charset=utf-8' }));
      a.download = `monitorg-${name}-${dkey(now)}.csv`; document.body.appendChild(a); a.click(); setTimeout(()=>{ URL.revokeObjectURL(a.href); a.remove(); }, 2000); };
    el.querySelectorAll('[data-bls-csv]').forEach(b=>b.onclick = () => {
      if(b.dataset.blsCsv==='market') save('rynok', [['Площадка','platform'],['Раздел',l=>SEC_RU[l.section]||l.section],['Тип объекта',l=>kOf(l).split('|')[1]],['Название','name'],['Стартовая цена, BYN','price'],['Первая цена, BYN','price0'],
        ['Заявки до',l=>{ const d = new Date(l.req_to*1000); return dt(l.req_to)+' '+p2(d.getHours())+':'+p2(d.getMinutes()); }],['Регион','region'],['Город / район','city'],['Место','location'],['Продавец','debtor'],['Площадь, м²','area_num'],
        ['Рынок, BYN',l=>l.market&&l.market.median||''],['Скидка к рынку, %',l=>disc(l)??''],['Ссылка','url']], market);
      else save('itogi', [['Дата торгов',x=>dt(x.at)],['Площадка','platform'],['Раздел',x=>SEC_RU[x.section]||x.section],['Тип объекта',x=>kOf(x).split('|')[1]],['Название','name'],['Регион','region'],['Город / район','city'],
        ['Итог',x=>(ST[x.st]||[x.st])[0]],['Начальная цена, BYN','start'],['Цена продажи, BYN',x=>g.sold(x)?x.price:''],['К начальной, %',x=>{ const v = g.pm(x); return v==null?'':Math.round(v); }],
        ['Участников','users'],['Ставок','bids'],['Круг торгов','rnd'],['Площадь, м²','area_num'],['Продавец','debtor'],['Ссылка','url']], S);
    });
  }

  // Колонки копии каталога, нужные аналитике
  const FIELDS = 'id,name,url,platform,section,price,price0,req_to,first_seen,closed,why,status,published,hidden_why,region,location,market,reasons,photo,area_num,debtor,result,city';
  // Данные — зашифрованным файлом с сайта (app/statsfile.rb, 15.10): имя и ключ двух последних файлов даёт база
  // только вошедшим (rpc stats_key). Новый не открылся — пробуем предыдущий; не открылся и он — ошибка,
  // и вызывающий берёт данные из базы, как раньше. Так аналитика не тратит бесплатный трафик базы.
  const b64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  const unpack = t => t.r.map(r => { const o = {}; t.c.forEach((k, i) => { o[k] = r[i]; }); return o; });
  async function openFile(p){
    const r = await fetch('/st/' + p.n + '.bin', { cache:'force-cache' });   // имя у каждой сборки новое — кэш не мешает
    if(!r.ok) throw new Error('сайт ответил ' + r.status);
    // файл: IV (16) + шифротекст AES-256-CBC + подпись HMAC-SHA256 (32); ключ — 64 байта: шифр и подпись
    const buf = await r.arrayBuffer(), k = b64(p.k), n = buf.byteLength - 32;
    if(n < 32) throw new Error('файл слишком короткий');
    const mk = await crypto.subtle.importKey('raw', k.slice(32), { name:'HMAC', hash:'SHA-256' }, false, ['verify']);
    if(!await crypto.subtle.verify('HMAC', mk, new Uint8Array(buf, n), new Uint8Array(buf, 0, n))) throw new Error('подпись не сходится');
    const ck = await crypto.subtle.importKey('raw', k.slice(0, 32), 'AES-CBC', false, ['decrypt']);
    const plain = await crypto.subtle.decrypt({ name:'AES-CBC', iv:new Uint8Array(buf, 0, 16) }, ck, new Uint8Array(buf, 16, n - 16));
    const d = JSON.parse(await new Response(new Blob([plain]).stream().pipeThrough(new DecompressionStream('gzip'))).text());
    if(d.v !== 1 || !d.lots || !d.sales || d.lots.r.length < 100) throw new Error('неполные данные');
    return { lots:unpack(d.lots), sales:unpack(d.sales), at:d.at };
  }
  async function load(getKeys){
    if(!(window.crypto && crypto.subtle && window.DecompressionStream)) throw new Error('браузер не умеет расшифровать файл');
    const ps = await getKeys();
    if(!Array.isArray(ps) || !ps.length) throw new Error('файл ещё не подключён');
    let err;
    for(const p of ps){ try{ return await openFile(p); }catch(e){ err = e; } }
    throw err;
  }
  window.BLStats = { render, load, BLOCKS, ADMIN_ONLY, FIELDS, DEFAULT_CAB: BLOCKS.map(b=>b[0]).filter(b=>!ADMIN_ONLY.includes(b)), OLD };
})();
