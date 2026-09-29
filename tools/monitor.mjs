// Монитор сайта: открывает страницы в настоящем Chrome (компьютер и iPhone) и ищет поломки.
//   node tools/monitor.mjs > tmp/monitor.json     (GitHub Actions, .github/workflows/monitor.yml)
// На выходе — JSON { checked, problems: [{ fp, title, detail }] }; сигнал в Telegram отправляет app/alert.rb.
// fp — отпечаток проблемы: одна и та же поломка не присылается каждые полчаса.
// Что ищем: сайт не открывается; ошибки JavaScript; файлы сайта не загрузились; страница шире экрана («половина экрана
// пустая» на телефоне); пустая страница; у лота нет подробностей, фото или итогов; мало лотов; сайт давно не обновлялся.
import puppeteer from 'puppeteer-core';

const BASE = process.env.SITE || 'https://ringo2122.github.io/bellot-site/';
const CHROME = process.env.CHROME || '/usr/bin/google-chrome';
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const VIEWS = [
  { name: 'компьютер', viewport: { width: 1366, height: 900 } },
  { name: 'телефон', viewport: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }, ua: IPHONE }
];
const NOISE = /favicon|translate\.google|mc\.yandex|yandex\.ru\/metrika|ERR_BLOCKED_BY_CLIENT/;
const problems = [];
let checked = 0;
const add = (fp, title, detail) => { if (!problems.some(p => p.fp === fp)) problems.push({ fp, title, detail: String(detail || '').slice(0, 600) }); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const short = u => u.replace(BASE, '').replace(/\?v=\d+/, '');

const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
try {
  for (const v of VIEWS) {
    const page = await browser.newPage();
    await page.setViewport(v.viewport);
    if (v.ua) await page.setUserAgent(v.ua);
    let where = 'главная';
    const errs = [];
    page.on('pageerror', e => errs.push([where, 'Ошибка JavaScript', e.message]));
    page.on('console', m => { if (m.type() === 'error' && !NOISE.test(m.text())) errs.push([where, 'Ошибка в консоли', m.text()]); });
    page.on('response', r => { const u = r.url(); if (u.startsWith(BASE) && r.status() >= 400) errs.push([where, `Файл сайта не отдаётся (HTTP ${r.status()})`, short(u)]); });
    page.on('requestfailed', r => { const u = r.url(); if (u.startsWith(BASE) && !NOISE.test(u)) errs.push([where, 'Файл сайта не загрузился', `${short(u)} — ${r.failure() && r.failure().errorText}`]); });

    let resp;
    try { resp = await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 60000 }); }
    catch (e) { add(`down`, 'Сайт не открывается', e.message); break; }
    if (!resp || resp.status() !== 200) { add('down', 'Сайт не открывается', `HTTP ${resp && resp.status()}`); break; }

    // что есть на сайте: число лотов, время сборки, случайный активный лот с фото и архивный с итогом
    const info = await page.evaluate(async () => {
      await loadArch();
      const pick = a => a[Math.floor(Math.random() * a.length)];
      const act = DATA.filter(l => l.photo), arc = ARCH.filter(l => l.result && ['sold', 'single', 'failed'].includes(l.result.st));
      document.startViewTransition = undefined;   // без анимаций переходов — проверка быстрее и стабильнее
      return { n: DATA.length, na: ARCH.length, snap: SNAP, lot: act.length ? pick(act).id : null, arch: arc.length ? pick(arc).id : null };
    });
    if (v.name === 'компьютер') {
      if (info.n < 500) add('few-lots', 'На сайте подозрительно мало лотов', `${info.n} активных (обычно 1 400–1 600)`);
      const age = Date.now() / 1000 - info.snap;
      if (age > 26 * 3600) add('stale', 'Сайт давно не обновлялся', `последняя сборка ${Math.round(age / 3600)} ч назад`);
    }

    const routes = [['главная', '#/'], ['каталог', '#/catalog'], ['раздел «Легковые»', '#/s/avto'], ['архив', '#/catalog?st=arch'],
                    ['калькулятор', '#/calc'], ['о платформе', '#/about']];
    if (info.lot) routes.push(['активный лот', `#/lot/${info.lot}`]);
    if (info.arch) routes.push(['лот в архиве', `#/lot/${info.arch}`]);
    for (const [name, hash] of routes) {
      where = name;
      await page.evaluate(h => { location.hash = h; }, hash);
      await sleep(hash.startsWith('#/lot/') ? 4500 : 2500);
      checked++;
      const r = await page.evaluate(isLot => {
        const out = [];
        // страница шире экрана: временно снимаем страховку overflow-x:clip, иначе поломку не видно
        const h = document.documentElement, b = document.body, ox = [h.style.overflowX, b.style.overflowX];
        h.style.overflowX = b.style.overflowX = 'visible';
        const sw = h.scrollWidth, iw = window.innerWidth;
        let wide = '';
        if (sw > iw + 2) {
          const el = [...document.querySelectorAll('#app *, header *, footer *')].find(e => { const q = e.getBoundingClientRect(); return q.width && q.right > iw + 2; });
          wide = el ? `${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''}${typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/)[0] : ''}` : '';
        }
        h.style.overflowX = ox[0]; b.style.overflowX = ox[1];
        if (sw > iw + 2) out.push(['wide', 'Страница шире экрана', `${sw} px при экране ${iw} px${wide ? ', выступает ' + wide : ''}`]);
        const app = document.getElementById('app');
        if (!app || app.innerText.trim().length < 80) out.push(['blank', 'Пустая страница', `текста на странице: ${app ? app.innerText.trim().length : 0} знаков`]);
        const t = app ? app.innerText : '';
        if (/Не получилось загрузить|Лот не найден/.test(t)) out.push(['fail', 'Страница показывает ошибку', t.match(/Не получилось загрузить[^\n]*|Лот не найден[^\n]*/)[0]]);
        if (isLot) {
          if (!document.querySelector('h1.lotname')) out.push(['lot-h1', 'Страница лота не отрисовалась', 'нет названия лота']);
          const acc = document.getElementById('accs');
          if (acc && /Подробных сведений площадка не опубликовала/.test(acc.innerText)) out.push(['lot-det', 'У лота нет подробностей', 'подробности не нашлись в пачке det']);
          if (acc && acc.querySelector('.skel')) out.push(['lot-det', 'Подробности лота не загрузились', 'вместо сведений — заглушка загрузки']);
          const img = document.querySelector('.gal img');
          if (img && img.complete && !img.naturalWidth && !/noph/.test(img.src)) out.push(['lot-img', 'Фото лота не загрузилось', img.src.replace(location.origin, '')]);
        }
        return out;
      }, hash.startsWith('#/lot/'));
      for (const [k, title, detail] of r) add(`${k}|${v.name}|${name}`, `${title} (${v.name}, ${name})`, `${detail} — ${BASE}${hash}`);
      if (hash === `#/lot/${info.arch}`) {
        const res = await page.evaluate(() => !!document.querySelector('.rres'));
        if (!res) add(`lot-res|${v.name}`, `У лота в архиве нет блока итогов (${v.name})`, `${BASE}${hash}`);
      }
    }
    for (const [w, title, detail] of errs) add(`err|${v.name}|${title}|${detail.slice(0, 80)}`, `${title} (${v.name}, ${w})`, detail);
    await page.close();
  }

  // админка: страница входа открывается без ошибок
  const page = await browser.newPage();
  const aerr = [];
  page.on('pageerror', e => aerr.push(e.message));
  const r = await page.goto(BASE + 'admin/', { waitUntil: 'networkidle2', timeout: 60000 }).catch(e => null);
  checked++;
  if (!r || r.status() !== 200) add('admin-down', 'Админка не открывается', `HTTP ${r && r.status()}`);
  else if (!(await page.$('input[type=password]'))) add('admin-form', 'В админке нет формы входа', BASE + 'admin/');
  for (const m of aerr) add(`admin-err|${m.slice(0, 80)}`, 'Ошибка JavaScript в админке', m);
} finally {
  await browser.close();
}
console.log(JSON.stringify({ checked, problems }, null, 1));
