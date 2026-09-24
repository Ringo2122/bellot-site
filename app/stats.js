/* БелЛот — аналитика рынка. Общая для админки и личного кабинета.
   Считается в браузере по копии каталога (таблица lots) и снимкам дня (daily).
   Рынок — активные лоты всех площадок без дублей и без скрытых админом.

   BLStats.render(el, { lots, daily, leads, bots, per, sec, blocks, href, site })
     blocks — какие блоки показать (id из BLStats.BLOCKS); по умолчанию все
     href(per, sec) — ссылка для переключателей периода и раздела
     site — путь к сайту для ссылок на лоты ('../' из админки, '' с сайта)
     leads, bots — только для админки (блок «Заявки и бот») */
(function(){
  const BLOCKS = [
    ['kpi', 'Главные цифры'], ['fresh', 'Новые лоты по дням'], ['size', 'Размер рынка по дням'],
    ['plat', 'Площадки'], ['sec', 'Разделы'], ['reg', 'Регионы'], ['prices', 'Стартовые цены'],
    ['disc', 'Скидка к рынку'], ['soon', 'Закрытие приёма заявок, 14 дней'], ['sqm', 'Недвижимость: цена м²'],
    ['sellers', 'Крупнейшие продавцы'], ['topdisc', 'Самая большая скидка'], ['drops', 'Снижение цены'],
    ['quality', 'Качество данных площадок'], ['demand', 'Заявки и Telegram-бот'], ['csv', 'Выгрузка в Excel']
  ];
  const ADMIN_ONLY = ['quality', 'demand'];   // в кабинет не отдаются, даже если отмечены
  const SECS = [['nedvizhimost','Недвижимость'],['avto','Легковые авто'],['gruz','Грузовые и автобусы'],['spec','Спецтехника'],['oborud','Оборудование']];
  const SEC_RU = Object.fromEntries(SECS);
  const PLATS = ['e-auction.by','ipmtorgi.by','beltorgi.by','cpo.by','konfiskat.by'];
  const COL = { nedvizhimost:'#12508f', avto:'#d9761f', gruz:'#1d7a4d', spec:'#7a4fa3', oborud:'#7b8794' };
  const REG = ['г. Минск','Минская область','Брестская область','Витебская область','Гомельская область','Гродненская область','Могилевская область'];

  const esc = s => String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const nf = n => n==null||n==='' ? '—' : Math.round(+n).toLocaleString('ru-RU');
  const p2 = n => String(n).padStart(2,'0');
  const plural = (n,a,b,c) => { n = Math.abs(n)%100; const m = n%10; return n>10&&n<20?c : m>1&&m<5?b : m===1?a : c; };
  const med = a => { if(!a.length) return null; const s = [...a].sort((x,y)=>x-y), m = s.length>>1; return s.length%2 ? s[m] : (s[m-1]+s[m])/2; };
  const big = n => n>=1e9 ? (n/1e9).toFixed(2).replace('.',',')+' млрд' : n>=1e6 ? (n/1e6).toFixed(1).replace('.',',')+' млн' : nf(n);
  const pc = (a, b) => b ? Math.round(a/b*100) + '%' : '—';
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
  @media (max-width:860px){ .bls .g2{grid-template-columns:1fr} }`;
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
    const lots = o.lots || [], daily = o.daily || [], per = o.per || '30', sec = o.sec || '', site = o.site || '';
    const on = new Set((o.blocks || BLOCKS.map(b=>b[0])).filter(b=>o.admin || !ADMIN_ONLY.includes(b)));
    const now = Date.now()/1000, from = per==='all' ? 0 : now - (+per)*86400;
    const inS = l => !sec || l.section===sec;
    const market = lots.filter(l=>l.status==='active' && !['dup','hidden'].includes(l.hidden_why) && inS(l));
    const onSite = lots.filter(l=>l.status==='active' && l.published && inS(l));
    const seenFrom = Math.min(...lots.filter(l=>l.first_seen).map(l=>l.first_seen));
    const fresh = lots.filter(l=>l.first_seen && l.first_seen>=from && l.hidden_why!=='dup' && inS(l));
    const done = lots.filter(l=>l.status==='archive' && l.closed>=from && inS(l));
    const val = a => a.reduce((s,l)=>s+(+l.price||0),0);
    const disc = l => l.market && l.market.median && !l.market.manual ? Math.round((l.market.median - l.price)/l.market.median*100) : null;
    const discs = market.map(disc).filter(x=>x!==null);
    const perTxt = { '7':'7 дней', '30':'30 дней', '90':'90 дней', all:'всё время' }[per];
    const link = l => `<a href="${site}#/lot/${encodeURIComponent(l.id)}" target="_blank" rel="noopener">${esc((l.name||'').slice(0,70))}</a>`;
    const regOf = l => REG.includes(l.region) ? l.region : 'не указан / другое';
    const regs = [...REG, 'не указан / другое'];
    const secsShown = SECS.filter(([s])=>!sec||s===sec);
    const P = [];   // панели по порядку

    if(on.has('fresh')){
      const startTs = per==='all' ? (isFinite(seenFrom) ? seenFrom : now) : Math.max(from, isFinite(seenFrom) ? seenFrom : from);
      const byDay = {}; fresh.forEach(l=>{ const k = dkey(l.first_seen); const d = byDay[k] ||= { total:0, parts:{} }; d.total++; d.parts[l.section] = (d.parts[l.section]||0) + 1; });
      const days = daysRange(startTs).map(k=>({ key:k, total:(byDay[k]||{}).total||0, parts:(byDay[k]||{}).parts }));
      P.push(`<div class="pnl"><h2>Новые лоты по дням</h2>${days.length?cols(days):'<p class="mut">Нет данных.</p>'}${legend()}</div>`);
    }
    if(on.has('size')){
      const dl = daily.filter(d=>per==='all' || new Date(d.day).getTime()/1000 >= from - 86400);
      const dyn = dl.map(d=>{ const st = d.stats||{}; return { key:d.day, total: sec ? ((st.by_section||{})[sec]||0) : st.active||0, parts: sec ? null : st.by_section }; });
      P.push(`<div class="pnl"><h2>Размер рынка по дням</h2>${dyn.length>=2 ? cols(dyn) + (sec?'':legend())
        : `<p class="mut">Снимок рынка сохраняется раз в день. Первый — ${dyn[0]?dshort(dyn[0].key):'сегодня'}; график появится со второго дня.</p>`}</div>`);
    }
    if(on.has('plat')){
      const rows = PLATS.map(p=>{ const m = market.filter(l=>l.platform===p), f = fresh.filter(l=>l.platform===p), s = onSite.filter(l=>l.platform===p);
        const merged = lots.filter(l=>l.platform===p && l.status==='active' && l.hidden_why==='dup' && inS(l)).length;
        const win = med(f.filter(l=>l.req_to>l.first_seen).map(l=>(l.req_to-l.first_seen)/86400));
        return [esc(p), nf(s.length), nf(m.length) + (merged?` <small class="mut">+${merged} дубл.</small>`:''), pc(m.length, market.length), nf(f.length),
          big(val(m)), nf(med(m.map(l=>+l.price).filter(x=>x>0))), win!=null&&m.length?Math.round(win)+' дн.':'—']; });
      P.push(`<div class="pnl"><h2>Площадки</h2>${tbl(['Площадка','На сайте','На рынке','Доля','Новых за период','Сумма стартовых цен, BYN','Медианная цена, BYN','Окно подачи заявок'], rows)}
        <p class="mut">Окно подачи заявок — медиана дней от появления лота до конца приёма заявок. «Дубл.» — лоты, склеенные с карточкой другой площадки.</p></div>`);
    }
    if(on.has('sec')){
      const rows = secsShown.map(([s,t])=>{ const m = market.filter(l=>l.section===s), pr = m.map(l=>+l.price).filter(x=>x>0), ds = m.map(disc).filter(x=>x!==null);
        return [`<span class="dot" style="background:${COL[s]}"></span>${t}`, nf(m.length), nf(fresh.filter(l=>l.section===s).length), nf(done.filter(l=>l.section===s).length),
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
    if(on.has('sqm')){
      const realty = lots.filter(l=>l.status==='active' && !['dup','hidden'].includes(l.hidden_why) && l.section==='nedvizhimost' && +l.area_num>0 && +l.area_num<=1000 && +l.price>0);
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
      P.push(`<div class="pnl"><h2>Самая большая скидка к рынку</h2>${top.length?tbl(['Лот','Площадка','Цена, BYN','Рынок, BYN','Скидка'], top.map(l=>[link(l), esc(l.platform), nf(l.price), nf(l.market.median), `<b>${disc(l)}%</b>`])):'<p class="mut">Нет данных.</p>'}
        <p class="mut">Большая скидка бывает и ошибкой сравнения: сравниваются обычные объявления, состояние объекта не учитывается.</p></div>`);
    }
    if(on.has('drops')){
      const drops = market.filter(l=>+l.price0>0 && +l.price<+l.price0).map(l=>[l, Math.round((l.price0-l.price)/l.price0*100)]).sort((a,b)=>b[1]-a[1]);
      P.push(`<div class="pnl"><h2>Снижение цены (повторные торги)</h2>${drops.length?`<p style="margin-top:0">${nf(drops.length)} ${plural(drops.length,'лот подешевел','лота подешевели','лотов подешевели')} с момента появления, медиана снижения — ${Math.round(med(drops.map(x=>x[1])))}%.</p>`
        + tbl(['Лот','Площадка','Было, BYN','Стало, BYN','Снижение'], drops.slice(0,10).map(([l,d])=>[link(l), esc(l.platform), nf(l.price0), nf(l.price), `<b>−${d}%</b>`]))
        : '<p class="mut">Пока ни один лот не подешевел — история цен копится с 24.09.2026.</p>'}</div>`);
    }
    if(on.has('quality')){
      const rows = PLATS.map(p=>{ const m = market.filter(l=>l.platform===p); if(!m.length) return null;
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
          <p class="mut">Конверсия в заявку появится, когда подключим счётчик посещений.</p></div>
        <div class="pnl"><h2>Telegram-бот за ${perTxt}</h2><p style="margin-top:0">Отправлено <b>${nf(bp.reduce((s,r)=>s+r.sent,0))}</b>.</p>${Object.keys(botBy).length?hbars(Object.entries(botBy).sort((a,b)=>b[1]-a[1]).map(([p,n])=>[p,n])):''}</div></div>`);
    }

    const href = o.href || ((p, s) => '#');
    el.innerHTML = `<div class="bls">
      <div class="tabs">${[['7','7 дней'],['30','30 дней'],['90','90 дней'],['all','Всё время']].map(([k,t])=>`<a href="${href(k, sec)}" class="${k===per?'on':''}">${t}</a>`).join('')}
        <span style="width:12px"></span><a href="${href(per,'')}" class="${!sec?'on':''}">Все разделы</a>${SECS.map(([k,t])=>`<a href="${href(per,k)}" class="${k===sec?'on':''}">${t}</a>`).join('')}</div>
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
      <p class="mut">Рынок — активные лоты всех площадок без дублей. Учёт новых лотов ведётся с ${isFinite(seenFrom)?dt(seenFrom):'—'}.</p>
    </div>`;
    const b = el.querySelector('[data-bls-csv]');
    if(b) b.onclick = () => {
      const C = [['Площадка','platform'],['Раздел',l=>SEC_RU[l.section]||l.section],['Название','name'],['Стартовая цена, BYN','price'],['Первая цена, BYN','price0'],
        ['Заявки до',l=>{ const d = new Date(l.req_to*1000); return dt(l.req_to)+' '+p2(d.getHours())+':'+p2(d.getMinutes()); }],['Регион','region'],['Место','location'],['Продавец','debtor'],['Площадь, м²','area_num'],
        ['Рынок, BYN',l=>l.market&&l.market.median||''],['Скидка к рынку, %',l=>disc(l)??''],['Ссылка','url']];
      const cv = v => { const s = String(v==null?'':v); return /[;"\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s; };
      const csv = '﻿' + [C.map(c=>c[0]).join(';'), ...market.map(l=>C.map(([,f])=>cv(typeof f==='function'?f(l):l[f])).join(';'))].join('\r\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type:'text/csv;charset=utf-8' }));
      a.download = `bellot-rynok-${dkey(now)}.csv`; a.click(); setTimeout(()=>URL.revokeObjectURL(a.href), 2000);
    };
  }

  // Колонки копии каталога, нужные аналитике
  const FIELDS = 'id,name,url,platform,section,price,price0,req_to,first_seen,closed,why,status,published,hidden_why,region,location,market,reasons,photo,area_num,debtor';
  window.BLStats = { render, BLOCKS, ADMIN_ONLY, FIELDS, DEFAULT_CAB: BLOCKS.map(b=>b[0]).filter(b=>!ADMIN_ONLY.includes(b)) };
})();
