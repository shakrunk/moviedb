/* ════════════════════════════════════════════════════════════════════════
   THE PROJECTION ROOM — client
   ════════════════════════════════════════════════════════════════════════ */
'use strict';

/* ── tiny helpers ─────────────────────────────────────────────────────── */
const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true"><use href="#ic-${name}"/></svg>`;

async function api(path, opts) {
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch (_) {}
  if (!res.ok) throw new Error((data && data.error) || `Request failed (${res.status})`);
  return data;
}

/* ── state ────────────────────────────────────────────────────────────── */
const state = {
  db: null,
  records: [],
  view: 'dashboard',
  mode: 'wall',
  sort: 'added-desc',
  filters: { search: '', status: 'all', genres: new Set(), minRating: 0, decade: null },
};
const posterMemo = new Map();    // "title|year" -> url|null
const posterTried = new Set();

// True when running behind the local PowerShell server; false on GitHub Pages / any static host.
const LOCAL_SERVER = ['localhost', '127.0.0.1'].includes(window.location.hostname);

/* ── domain helpers ───────────────────────────────────────────────────── */
const yearOf = (r) => { const m = /(\d{4})/.exec(r.ReleaseDate || ''); return m ? m[1] : ''; };
const genresOf = (r) => (r.Genre || '').split(',').map((g) => g.trim()).filter(Boolean);
const watchDates = (r) => (Array.isArray(r.WatchDate) ? r.WatchDate : (r.WatchDate ? [r.WatchDate] : [])).filter(Boolean);
const lastWatch = (r) => { const d = watchDates(r).slice().sort(); return d.length ? d[d.length - 1] : ''; };
// A meaningful re-watch: more than one logged viewing, or a dated watch of a film you'd seen before.
// (watched_no_date entries are PriorWatch=true by convention, so we don't flag those as "re-watches".)
const isRewatch = (r) => watchDates(r).length > 1 || (r.Status === 'watched' && r.PriorWatch === true);

function runtimeMin(r) {
  const m = /^(\d+):(\d+)(?::(\d+))?$/.exec((r.Runtime || '').trim());
  if (!m) return 0;
  return (+m[1]) * 60 + (+m[2]) + (m[3] ? Math.round(+m[3] / 60) : 0);
}
function fmtRuntime(r) {
  const t = runtimeMin(r);
  if (!t) return '';
  const h = Math.floor(t / 60), mm = t % 60;
  return h ? `${h}h ${mm.toString().padStart(2, '0')}m` : `${mm}m`;
}
const seenCount = (r) =>
  r.Status === 'watched' ? Math.max(watchDates(r).length, 1) : (r.Status === 'watched_no_date' ? 1 : 0);

const STATUS = {
  watched:         { label: 'Watched',   short: 'Seen' },
  watched_no_date: { label: 'Archive',   short: 'Archive' },
  want_to_watch:   { label: 'Watchlist', short: 'Queued' },
};

/* genre → muted duotone tint */
const TINTS = {
  'science fiction': '#6f8fa6', 'sci-fi': '#6f8fa6', 'drama': '#b5895a', 'thriller': '#7d7088',
  'mystery': '#5f7d85', 'action': '#b3654a', 'adventure': '#8c8550', 'comedy': '#c39a4e',
  'crime': '#8c5a52', 'horror': '#7e4a48', 'romance': '#b26a78', 'animation': '#6a93a1',
  'family': '#7fa069', 'fantasy': '#8a6fa0', 'documentary': '#9a8f78', 'survival': '#9a7a4a',
  'short': '#88808f', 'war': '#74705a', 'western': '#a9794c',
};
const tintOf = (r) => { const g = (genresOf(r)[0] || '').toLowerCase(); return TINTS[g] || '#6b7480'; };

function relDate(iso) {
  if (!iso) return '';
  const d = new Date(iso + 'T00:00:00');
  if (isNaN(d)) return iso;
  const days = Math.round((Date.now() - d.getTime()) / 86400000);
  if (days <= 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days < 30) return `${days} days ago`;
  if (days < 365) { const m = Math.round(days / 30); return `${m} month${m > 1 ? 's' : ''} ago`; }
  const y = Math.round(days / 365); return `${y} year${y > 1 ? 's' : ''} ago`;
}
function prettyDate(iso) {
  const d = new Date(iso + 'T00:00:00');
  if (isNaN(d)) return iso;
  return d.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
}

function starsHTML(rating, { interactive = false } = {}) {
  let h = '';
  for (let i = 1; i <= 5; i++) {
    const on = rating && i <= rating;
    h += `<svg class="${on ? '' : 'empty'}" ${interactive ? `data-n="${i}"` : ''} viewBox="0 0 24 24"><use href="#ic-star-${on ? 'fill' : 'fill'}"/></svg>`;
  }
  return h;
}

/* ── data load ────────────────────────────────────────────────────────── */
async function loadDb() {
  if (LOCAL_SERVER) {
    state.db = await api('/api/db');
  } else {
    const res = await fetch('movies.json');
    if (!res.ok) throw new Error(`Could not load movies.json (${res.status})`);
    state.db = await res.json();
  }
  state.records = (state.db.log || []).map((r, i) => ({ ...r, _idx: i }));
}

/* ════════════════════════════════════════════════════════════════════════
   FILTER + SORT
   ════════════════════════════════════════════════════════════════════════ */
function filtered() {
  const f = state.filters;
  const q = f.search.trim().toLowerCase();
  let rows = state.records.filter((r) => {
    if (f.status !== 'all' && r.Status !== f.status) return false;
    if (f.minRating && !(r.Rating >= f.minRating)) return false;
    if (f.genres.size) {
      const gs = genresOf(r).map((g) => g.toLowerCase());
      if (![...f.genres].some((g) => gs.includes(g))) return false;
    }
    if (f.decade != null) { const y = +yearOf(r); if (!(y >= f.decade && y < f.decade + 10)) return false; }
    if (q) {
      const hay = [r.Title, r.Director, r.Genre, r.Actors, r.Studio, r.Notes].join(' ').toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });

  const byNum = (sel, dir) => (a, b) => (sel(b) - sel(a)) * dir;
  const sorters = {
    'added-desc': (a, b) => b._idx - a._idx,
    'watch-desc': (a, b) => (lastWatch(b) || '').localeCompare(lastWatch(a) || ''),
    'rating-desc': byNum((r) => r.Rating || 0, 1),
    'rating-asc':  byNum((r) => r.Rating || 99, -1),
    'title-asc': (a, b) => a.Title.localeCompare(b.Title),
    'year-desc': byNum((r) => +yearOf(r) || 0, 1),
    'year-asc':  byNum((r) => +yearOf(r) || 9999, -1),
    'runtime-desc': byNum(runtimeMin, 1),
  };
  rows.sort(sorters[state.sort] || sorters['added-desc']);
  return rows;
}

/* ════════════════════════════════════════════════════════════════════════
   RENDER — top level
   ════════════════════════════════════════════════════════════════════════ */
function render() {
  $$('.navtab').forEach((t) => t.classList.toggle('is-active', t.dataset.go === state.view));
  $('#view-dashboard').hidden = state.view !== 'dashboard';
  $('#view-library').hidden = state.view !== 'library';
  document.body.dataset.view = state.view;
  if (state.view === 'dashboard') renderDashboard();
  else renderLibrary();
}

function setView(v) { state.view = v; render(); window.scrollTo({ top: 0, behavior: 'smooth' }); }

/* ════════════════════════════════════════════════════════════════════════
   DASHBOARD
   ════════════════════════════════════════════════════════════════════════ */
function renderDashboard() {
  const recs = state.records;
  const seen = recs.filter((r) => r.Status !== 'want_to_watch');
  const rated = recs.filter((r) => r.Rating);
  const avg = rated.length ? (rated.reduce((s, r) => s + r.Rating, 0) / rated.length) : 0;
  const totalMin = recs.reduce((s, r) => s + runtimeMin(r) * seenCount(r), 0);
  const hours = Math.round(totalMin / 60);
  const thisYear = new Date().getFullYear();
  const seenThisYear = recs.reduce((s, r) => s + watchDates(r).filter((d) => d.startsWith(thisYear)).length, 0);
  const watchlist = recs.filter((r) => r.Status === 'want_to_watch').length;

  $('#todayStr').textContent = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  $('#dashLede').innerHTML =
    `<strong>${recs.length} titles</strong> rest in the archive — ${seen.length} already seen` +
    (watchlist ? `, <strong>${watchlist}</strong> waiting in the wings` : '') +
    `. That's <strong>${hours.toLocaleString()} hours</strong> in the dark, with the average picture earning ` +
    `<strong>${avg ? avg.toFixed(1) : '—'}</strong> of five.`;

  const stat = (ic, num, unit, label, sub) => `
    <div class="stat-card">
      <svg class="stat-icon" viewBox="0 0 24 24"><use href="#ic-${ic}"/></svg>
      <div class="stat-num">${num}${unit ? `<span class="unit">${unit}</span>` : ''}</div>
      <div class="stat-label">${label}</div>${sub ? `<div class="stat-sub">${sub}</div>` : ''}
    </div>`;
  $('#statStrip').innerHTML =
    stat('reel', recs.length, '', 'Titles in the archive') +
    stat('clock', hours.toLocaleString(), 'hrs', 'Hours in the dark', `${(totalMin / 60 / 24).toFixed(1)} days of cinema`) +
    stat('star', avg ? avg.toFixed(1) : '—', avg ? '/5' : '', 'Average rating', `${rated.length} rated`) +
    stat('calendar', seenThisYear, '', `Screenings in ${thisYear}`) +
    stat('eye', watchlist, '', 'On the watchlist', watchlist ? 'ready when you are' : 'all caught up');

  renderRatings(recs);
  renderGenreBars(recs);
  renderTimeline(recs);
  renderDirectors(recs);
  renderRecent(recs);
}

function renderRatings(recs) {
  const counts = [0, 0, 0, 0, 0, 0]; // index 0 = unrated
  recs.forEach((r) => counts[r.Rating || 0]++);
  const max = Math.max(1, ...counts.slice(1), counts[0]);
  let h = '';
  for (let s = 5; s >= 1; s--) {
    let stars = '';
    for (let i = 0; i < 5; i++) stars += `<svg class="${i < s ? '' : 'empty'}" viewBox="0 0 24 24" style="color:${i < s ? '' : 'rgba(255,255,255,.12)'}"><use href="#ic-star-fill"/></svg>`;
    h += `<div class="rrow"><div class="rrow__stars">${stars}</div>
      <div class="rrow__track"><div class="rrow__fill" style="width:${(counts[s] / max) * 100}%;animation-delay:${(5 - s) * 70}ms"></div></div>
      <div class="rrow__val">${counts[s]}</div></div>`;
  }
  h += `<div class="rrow"><div class="rrow__stars" style="font-family:var(--mono);font-size:11px;color:var(--paper-faint);align-items:center">unrated</div>
    <div class="rrow__track"><div class="rrow__fill" style="width:${(counts[0] / max) * 100}%;background:linear-gradient(90deg,#3a332c,#6f655a);animation-delay:380ms"></div></div>
    <div class="rrow__val">${counts[0]}</div></div>`;
  $('#ratingsChart').innerHTML = h;
}

function renderGenreBars(recs) {
  const tally = {};
  recs.forEach((r) => genresOf(r).forEach((g) => { tally[g] = (tally[g] || 0) + 1; }));
  const top = Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 8);
  const max = Math.max(1, ...top.map((t) => t[1]));
  $('#genreBars').innerHTML = top.map(([g, n], i) => {
    const tint = TINTS[g.toLowerCase()] || '#9a8f78';
    return `<div class="gbar" data-genre="${esc(g.toLowerCase())}">
      <div class="gbar__name">${esc(g)}</div>
      <div class="gbar__track"><div class="gbar__fill" style="width:${(n / max) * 100}%;background:linear-gradient(90deg,${tint}88,${tint});animation-delay:${i * 60}ms"></div></div>
      <div class="gbar__val">${n}</div></div>`;
  }).join('');
  $$('#genreBars .gbar').forEach((el) => el.onclick = () => {
    state.filters.genres = new Set([el.dataset.genre]);
    setView('library'); syncFilterUI();
  });
}

function renderTimeline(recs) {
  const all = [];
  recs.forEach((r) => watchDates(r).forEach((d) => all.push(d.slice(0, 7))));
  const panel = $('.panel--timeline');
  if (!all.length) { panel.hidden = true; return; }
  panel.hidden = false;
  const counts = {};
  all.forEach((m) => counts[m] = (counts[m] || 0) + 1);
  const keys = Object.keys(counts).sort();
  const [sy, sm] = keys[0].split('-').map(Number);
  const [ey, em] = keys[keys.length - 1].split('-').map(Number);
  const months = [];
  let y = sy, m = sm;
  while (y < ey || (y === ey && m <= em)) {
    months.push(`${y}-${String(m).padStart(2, '0')}`);
    m++; if (m > 12) { m = 1; y++; }
  }
  const max = Math.max(1, ...Object.values(counts));
  const showLbl = months.length > 14 ? 3 : 1;
  $('#timeline').innerHTML = months.map((mo, i) => {
    const c = counts[mo] || 0;
    const [yy, mm] = mo.split('-');
    const lbl = (i % showLbl === 0) ? `${['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][+mm]} '${yy.slice(2)}` : '';
    return `<div class="tcol" title="${c} screening${c !== 1 ? 's' : ''} · ${mo}">
      <div class="tcol__cnt">${c || ''}</div>
      <div class="tcol__bar" data-empty="${c ? 0 : 1}" style="height:${c ? Math.max(8, (c / max) * 100) : 4}%;animation-delay:${i * 28}ms"></div>
      <div class="tcol__lbl">${lbl}</div></div>`;
  }).join('');
}

function renderDirectors(recs) {
  const tally = {};
  recs.forEach((r) => { const d = (r.Director || '').trim(); if (d) tally[d] = (tally[d] || 0) + 1; });
  const top = Object.entries(tally).filter((t) => t[1] > 1).sort((a, b) => b[1] - a[1]).slice(0, 6);
  if (!top.length) { Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 6).forEach((t) => top.push(t)); }
  $('#directorList').innerHTML = top.map(([d, n], i) => `
    <li class="dir-item" data-dir="${esc(d)}">
      <span class="dir-rank">${String(i + 1).padStart(2, '0')}</span>
      <span class="dir-name">${esc(d)}</span>
      <span class="dir-meta"><span class="dir-dots">${'<i></i>'.repeat(Math.min(n, 5))}</span><span class="dir-count">${n}</span></span>
    </li>`).join('');
  $$('#directorList .dir-item').forEach((el) => el.onclick = () => {
    state.filters.search = el.dataset.dir; setView('library'); syncFilterUI();
  });
}

function renderRecent(recs) {
  let list = recs.filter((r) => lastWatch(r)).sort((a, b) => lastWatch(b).localeCompare(lastWatch(a)));
  if (list.length < 6) list = recs.slice().sort((a, b) => b._idx - a._idx);
  list = list.slice(0, 12);
  $('#recentStrip').innerHTML = list.map((r) => `
    <div class="recent-card" data-idx="${r._idx}">
      <div class="mini-poster" data-title="${esc(r.Title)}" data-year="${yearOf(r)}" style="--tint:${tintOf(r)}">
        ${miniFaceHTML(r)}
      </div>
      <div class="rc-title">${esc(r.Title)}</div>
      <div class="rc-date">${lastWatch(r) ? relDate(lastWatch(r)) : 'added'}</div>
    </div>`).join('');
  $$('#recentStrip .recent-card').forEach((el) => el.onclick = () => openDrawer(state.records.find((r) => r._idx === +el.dataset.idx)));
  observePosters($('#recentStrip'));
}

function miniFaceHTML(r) {
  return `<div class="poster__face" style="padding:10px"><div class="poster__body">
    <div class="p-title" style="font-size:13px;-webkit-line-clamp:3">${esc(r.Title)}</div>
    <div class="p-meta" style="font-size:9px;margin-top:4px">${yearOf(r)}</div></div></div>`;
}

/* ════════════════════════════════════════════════════════════════════════
   LIBRARY
   ════════════════════════════════════════════════════════════════════════ */
function renderLibrary() {
  ensureFilterChips();
  const rows = filtered();

  // result meta
  const rated = rows.filter((r) => r.Rating);
  const avg = rated.length ? (rated.reduce((s, r) => s + r.Rating, 0) / rated.length).toFixed(1) : null;
  $('#resultMeta').innerHTML = `<b>${rows.length}</b> of ${state.records.length} titles` +
    (avg ? ` &nbsp;·&nbsp; avg <b>${avg}</b>/5 across ${rated.length} rated` : '');

  const empty = rows.length === 0;
  $('#emptyState').hidden = !empty;
  $('#wall').hidden = empty || state.mode !== 'wall';
  $('#ledgerWrap').hidden = empty || state.mode !== 'list';

  if (empty) return;
  if (state.mode === 'wall') renderWall(rows);
  else renderLedger(rows);
}

function renderWall(rows) {
  const wall = $('#wall');
  wall.innerHTML = rows.map((r, i) => posterHTML(r, i)).join('');
  $$('.poster', wall).forEach((el) => el.onclick = () => openDrawer(state.records.find((r) => r._idx === +el.dataset.idx)));
  observePosters(wall);
}

function posterHTML(r, i) {
  const y = yearOf(r), rt = fmtRuntime(r), dir = r.Director || '';
  const st = r.Status;
  const badge = st === 'watched'
    ? `<span class="p-badge" data-s="watched">${icon('check')}seen</span>`
    : st === 'want_to_watch'
      ? `<span class="p-badge" data-s="want_to_watch">${icon('eye')}queued</span>`
      : `<span class="p-badge" data-s="watched_no_date">archive</span>`;
  const rewatch = isRewatch(r)
    ? `<span class="p-rewatch p-badge" data-s="watched" title="re-watch">${icon('repeat')}</span>` : '';
  return `
  <article class="poster" data-idx="${r._idx}" data-title="${esc(r.Title)}" data-year="${y}"
           style="--tint:${tintOf(r)};animation-delay:${Math.min(i * 35, 600)}ms">
    <img class="poster__img" alt="" loading="lazy" />
    ${rewatch}
    <div class="poster__face">
      <div class="poster__top"><span class="p-cat">NO.&nbsp;${String(r._idx + 1).padStart(3, '0')}</span>${badge}</div>
      <div class="poster__body">
        <h3 class="p-title">${esc(r.Title)}</h3>
        <div class="p-meta">${y ? `<span>${y}</span>` : ''}${y && rt ? '<span class="sep">·</span>' : ''}${rt ? `<span>${rt}</span>` : ''}</div>
        ${dir ? `<div class="p-dir">${esc(dir)}</div>` : ''}
        ${r.Rating ? `<div class="p-stars">${starsHTML(r.Rating)}</div>` : ''}
      </div>
    </div>
  </article>`;
}

function renderLedger(rows) {
  $('#ledgerBody').innerHTML = rows.map((r) => {
    const y = yearOf(r), lw = lastWatch(r);
    const rew = isRewatch(r) ? `<span class="repeat" title="re-watch">${icon('repeat')}</span>` : '';
    return `<tr data-idx="${r._idx}">
      <td class="col-no"><span class="led-no">${String(r._idx + 1).padStart(3, '0')}</span></td>
      <td><span class="led-title">${esc(r.Title)}</span>${rew}</td>
      <td><span class="led-year">${y || '—'}</span></td>
      <td><span class="led-stars">${r.Rating ? starsHTML(r.Rating) : '<span style="color:var(--paper-faint);font-family:var(--mono);font-size:12px">—</span>'}</span></td>
      <td><span class="led-runtime">${fmtRuntime(r) || '—'}</span></td>
      <td class="col-genre"><span class="led-genre">${esc(genresOf(r).slice(0, 2).join(', ') || '—')}</span></td>
      <td class="col-director"><span class="led-director">${esc(r.Director || '—')}</span></td>
      <td><span class="led-status" data-s="${r.Status}"><i></i>${STATUS[r.Status]?.label || r.Status}</span></td>
      <td><span class="led-watch">${lw || '—'}</span></td>
    </tr>`;
  }).join('');
  $$('#ledgerBody tr').forEach((tr) => tr.onclick = () => openDrawer(state.records.find((r) => r._idx === +tr.dataset.idx)));
}

/* ── poster lazy loading (progressive enhancement; no-ops gracefully) ──── */
let posterObserver;
function observePosters(root) {
  if (!posterObserver) {
    posterObserver = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { loadPoster(e.target); posterObserver.unobserve(e.target); } });
    }, { rootMargin: '300px' });
  }
  $$('[data-title]', root).forEach((el) => posterObserver.observe(el));
}
async function loadPoster(el) {
  const title = el.dataset.title, year = el.dataset.year || '';
  if (!title) return;
  const key = `${title}|${year}`.toLowerCase();
  let url = posterMemo.get(key);
  if (url === undefined && !posterTried.has(key)) {
    posterTried.add(key);
    try {
      url = LOCAL_SERVER
        ? (await api(`/api/poster?title=${encodeURIComponent(title)}&year=${encodeURIComponent(year)}`)).url || null
        : await fetchITunesPoster(title, year);
      posterMemo.set(key, url);
    } catch (_) { url = null; }
  }
  if (!url) return;
  const img = $('.poster__img', el) || $('img', el);
  if (img) { img.src = url; img.onload = () => el.classList.add('has-img'); }
}

async function fetchITunesPoster(title, year) {
  const term = year ? `${title} ${year}` : title;
  const res = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(term)}&country=US&entity=movie&limit=5`);
  if (!res.ok) return null;
  const data = await res.json();
  if (!data.resultCount) return null;
  let best = data.results.find((m) => m.artworkUrl100);
  if (year) {
    const ym = data.results.find((m) => m.artworkUrl100 && m.releaseDate?.startsWith(year));
    if (ym) best = ym;
  }
  return best?.artworkUrl100?.replace(/\d+x\d+bb/, '600x600bb') || null;
}

/* ════════════════════════════════════════════════════════════════════════
   FILTER UI
   ════════════════════════════════════════════════════════════════════════ */
let chipsBuilt = false;
function ensureFilterChips() {
  if (chipsBuilt) return;
  chipsBuilt = true;
  // genre chips
  const tally = {};
  state.records.forEach((r) => genresOf(r).forEach((g) => tally[g] = (tally[g] || 0) + 1));
  const genres = Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 16).map((t) => t[0]);
  $('#genreChips').innerHTML = genres.map((g) =>
    `<button class="chip" data-genre="${esc(g.toLowerCase())}">${esc(g)}</button>`).join('');
  $$('#genreChips .chip').forEach((c) => c.onclick = () => {
    const g = c.dataset.genre;
    state.filters.genres.has(g) ? state.filters.genres.delete(g) : state.filters.genres.add(g);
    syncFilterUI(); renderLibrary();
  });
  // rating filter
  let rf = '';
  for (let i = 1; i <= 5; i++) rf += `<button class="rfstar" data-n="${i}">${icon('star-fill')}</button>`;
  $('#ratingFilter').innerHTML = rf;
  $$('#ratingFilter .rfstar').forEach((s) => s.onclick = () => {
    const n = +s.dataset.n;
    state.filters.minRating = state.filters.minRating === n ? 0 : n;
    syncFilterUI(); renderLibrary();
  });
  // decades
  const decs = [...new Set(state.records.map((r) => { const y = +yearOf(r); return y ? Math.floor(y / 10) * 10 : null; }).filter(Boolean))].sort((a, b) => b - a);
  $('#decadeChips').innerHTML = decs.map((d) => `<button class="chip" data-dec="${d}">${d}s</button>`).join('');
  $$('#decadeChips .chip').forEach((c) => c.onclick = () => {
    const d = +c.dataset.dec;
    state.filters.decade = state.filters.decade === d ? null : d;
    syncFilterUI(); renderLibrary();
  });
}
function syncFilterUI() {
  const f = state.filters;
  $('#searchInput').value = f.search;
  $('#searchClear').hidden = !f.search;
  $$('#statusSeg .seg__btn').forEach((b) => b.classList.toggle('is-active', b.dataset.status === f.status));
  $$('#genreChips .chip').forEach((c) => c.classList.toggle('is-active', f.genres.has(c.dataset.genre)));
  $$('#decadeChips .chip').forEach((c) => c.classList.toggle('is-active', f.decade === +c.dataset.dec));
  $$('#ratingFilter .rfstar').forEach((s) => s.classList.toggle('is-on', +s.dataset.n <= f.minRating));
  const active = f.genres.size || f.minRating || f.decade != null;
  if (active && $('#filterbar').hidden) $('#filterbar').hidden = false;
}

/* ════════════════════════════════════════════════════════════════════════
   DETAIL DRAWER
   ════════════════════════════════════════════════════════════════════════ */
function openDrawer(r) {
  if (!r) return;
  const y = yearOf(r), key = `${r.Title}|${y}`.toLowerCase();
  const poster = posterMemo.get(key);
  const tags = [y, fmtRuntime(r), genresOf(r)[0]].filter(Boolean);
  const facts = [];
  const fact = (k, v, wide) => { if (v) facts.push(`<div class="dr-fact${wide ? ' dr-fact--wide' : ''}"><dt>${k}</dt><dd>${esc(v)}</dd></div>`); };
  fact('Released', r.ReleaseDate ? prettyDate(r.ReleaseDate) : '');
  fact('Runtime', fmtRuntime(r));
  fact('Director', r.Director, true);
  fact('Studio', r.Studio, true);
  fact('Genre', genresOf(r).join(' · '), true);
  fact('Cast', r.Actors, true);
  const priorTxt = r.PriorWatch === true ? 'Seen before (re-watch)' : r.PriorWatch === false ? 'First-time viewing' : '';
  fact('Viewing', priorTxt);

  const dates = watchDates(r).slice().sort();
  const stubs = dates.length
    ? `<div class="dr-section"><h3>Screening history — ${dates.length} ${dates.length === 1 ? 'viewing' : 'viewings'}</h3>
        <div class="stubs">${dates.slice().reverse().map((d) => `
          <div class="stub">${icon('ticket')}<span class="stub__date">${prettyDate(d)}</span><span class="stub__rel">${relDate(d)}</span></div>`).join('')}</div></div>`
    : '';

  const canWatchToday = !dates.includes(new Date().toISOString().slice(0, 10));

  $('#drawerInner').innerHTML = `
    <div class="dr-hero" style="--tint:${tintOf(r)}">
      <button class="icon-btn dr-close" id="drClose">${icon('x')}</button>
      <div class="dr-head">
        <div class="dr-poster">${poster ? `<img src="${esc(poster)}" alt="">` : miniFaceHTML(r)}</div>
        <div>
          <div class="dr-cat">No. ${String(r._idx + 1).padStart(3, '0')} · ${STATUS[r.Status]?.label || r.Status}</div>
          <h2 class="dr-title">${esc(r.Title)}</h2>
          <div class="dr-tagline">${tags.map((t) => `<span>${esc(t)}</span>`).join('')}</div>
          <div class="dr-stars" id="drStars">${starsHTML(r.Rating, { interactive: true })}<span class="dr-rate-hint">click to rate</span></div>
        </div>
      </div>
    </div>
    <div class="dr-body">
      <div class="dr-actions">
        <button class="btn btn--amber" id="drEdit">${icon('pencil')}<span>Edit</span></button>
        ${canWatchToday ? `<button class="btn btn--ghost" id="drWatch">${icon('check')}<span>Log a watch today</span></button>` : ''}
        <button class="btn btn--ghost" id="drDelete">${icon('trash')}<span>Delete</span></button>
      </div>
      <div class="dr-section"><h3>Notes</h3>
        <p class="dr-notes ${r.Notes ? '' : 'is-empty'}">${r.Notes ? esc(r.Notes) : 'No notes recorded for this title.'}</p></div>
      ${stubs}
      <div class="dr-section"><h3>Particulars</h3><div class="dr-facts">${facts.join('') || '<div class="dr-fact dr-fact--wide"><dd style="color:var(--paper-faint)">No metadata recorded.</dd></div>'}</div></div>
    </div>`;

  // wire
  $('#drClose').onclick = closeDrawer;
  $('#drEdit').onclick = () => { closeDrawer(); openModal(r); };
  $('#drDelete').onclick = () => deleteMovie(r);
  if ($('#drWatch')) $('#drWatch').onclick = () => markWatched(r);
  wireStarRating($('#drStars'), r.Rating, (n) => quickRate(r, n));

  $('#scrim').hidden = false;
  requestAnimationFrame(() => { $('#scrim').classList.add('is-open'); $('#drawer').classList.add('is-open'); });
  $('#drawer').setAttribute('aria-hidden', 'false');
  // load poster into drawer if not yet known
  if (poster === undefined) loadDrawerPoster(r);
}
async function loadDrawerPoster(r) {
  const y = yearOf(r), key = `${r.Title}|${y}`.toLowerCase();
  try {
    const url = LOCAL_SERVER
      ? (await api(`/api/poster?title=${encodeURIComponent(r.Title)}&year=${encodeURIComponent(y)}`)).url || null
      : await fetchITunesPoster(r.Title, y);
    posterMemo.set(key, url);
    if (url) { const p = $('.dr-poster'); if (p) p.innerHTML = `<img src="${esc(url)}" alt="">`; }
  } catch (_) {}
}
function closeDrawer() {
  $('#drawer').classList.remove('is-open');
  $('#scrim').classList.remove('is-open');
  $('#drawer').setAttribute('aria-hidden', 'true');
  setTimeout(() => { if (!$('#modal').classList.contains('is-open')) $('#scrim').hidden = true; }, 420);
}

function wireStarRating(container, current, onPick) {
  const stars = $$('svg[data-n]', container);
  const paint = (val) => stars.forEach((s) => {
    const on = +s.dataset.n <= val;
    s.classList.toggle('empty', !on);
  });
  stars.forEach((s) => {
    s.onmouseenter = () => paint(+s.dataset.n);
    s.onclick = () => onPick(+s.dataset.n);
  });
  container.onmouseleave = () => paint(current || 0);
}

/* ════════════════════════════════════════════════════════════════════════
   MUTATIONS
   ════════════════════════════════════════════════════════════════════════ */
async function reloadAndRender() {
  await loadDb();
  chipsBuilt = false;
  render();
}

async function quickRate(r, n) {
  if (!LOCAL_SERVER) { toast('Rating is read-only in the published archive', 'info'); return; }
  try {
    const next = { ...r, Rating: r.Rating === n ? null : n };
    state.db = await api(`/api/movies/${r._idx}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next) });
    await reloadAndRender();
    const updated = state.records.find((x) => x._idx === r._idx);
    if (updated) openDrawer(updated);
    toast(next.Rating ? `Rated ${'★'.repeat(next.Rating)} — ${r.Title}` : `Cleared rating — ${r.Title}`, 'ok');
  } catch (e) { toast(e.message, 'err'); }
}

async function markWatched(r) {
  if (!LOCAL_SERVER) { toast('Logging is read-only in the published archive', 'info'); return; }
  try {
    const today = new Date().toISOString().slice(0, 10);
    const dates = [...new Set([...watchDates(r), today])].sort();
    const prior = r.PriorWatch == null ? (r.Status === 'want_to_watch' ? false : r.PriorWatch) : r.PriorWatch;
    const next = { ...r, WatchDate: dates, Status: 'watched', PriorWatch: prior };
    await api(`/api/movies/${r._idx}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next) });
    await reloadAndRender();
    const updated = state.records.find((x) => x._idx === r._idx);
    if (updated) openDrawer(updated);
    toast(`Logged a screening — ${r.Title}`, 'ok');
  } catch (e) { toast(e.message, 'err'); }
}

async function deleteMovie(r) {
  if (!LOCAL_SERVER) { toast('Deletion is read-only in the published archive', 'info'); return; }
  if (!confirm(`Permanently remove “${r.Title}” from the archive?`)) return;
  try {
    await api(`/api/movies/${r._idx}`, { method: 'DELETE' });
    closeDrawer();
    await reloadAndRender();
    toast(`Removed — ${r.Title}`, 'info');
  } catch (e) { toast(e.message, 'err'); }
}

/* ════════════════════════════════════════════════════════════════════════
   ADD / EDIT MODAL
   ════════════════════════════════════════════════════════════════════════ */
let modalState = null;
function openModal(rec = null) {
  if (!LOCAL_SERVER) { toast('The published archive is read-only', 'info'); return; }
  const isNew = !rec;
  modalState = {
    isNew, idx: rec ? rec._idx : null,
    rating: rec?.Rating || null,
    status: rec?.Status || 'watched',
    dates: rec ? watchDates(rec).slice().sort() : [],
    prior: rec?.PriorWatch ?? null,
  };
  const g = (k) => esc(rec?.[k] || '');
  $('#modalPanel').innerHTML = `
    <div class="modal__head">
      <div><p class="kicker"><span class="dot"></span> ${isNew ? 'new acquisition' : 'revise the record'}</p>
      <h2>${isNew ? 'Add a Title' : esc(rec.Title)}</h2></div>
      <button class="icon-btn" id="mClose">${icon('x')}</button>
    </div>
    <div class="modal__body">
      <div class="field">
        <label>Title</label>
        <div class="title-field">
          <input class="input" id="fTitle" value="${g('Title')}" placeholder="Film title" autocomplete="off"/>
          <button class="btn btn--ghost" id="fFetch">${icon('sparkle')}<span>Fetch</span></button>
        </div>
        <div id="itunesBox"></div>
      </div>

      <div class="field">
        <label>Status</label>
        <div class="statuspick" id="fStatus">
          <div class="statuspick__opt" data-v="watched"><div class="sp-name">Watched</div><div class="sp-desc">Seen — with a date</div></div>
          <div class="statuspick__opt" data-v="watched_no_date"><div class="sp-name">Archive</div><div class="sp-desc">Seen — date unknown</div></div>
          <div class="statuspick__opt" data-v="want_to_watch"><div class="sp-name">Watchlist</div><div class="sp-desc">Not yet seen</div></div>
        </div>
      </div>

      <div class="field-row">
        <div class="field">
          <label>Rating</label>
          <div class="ratepick" id="fRating">
            ${[1,2,3,4,5].map((i) => `<button class="ratepick__star" data-n="${i}">${icon('star-fill')}</button>`).join('')}
            <button class="ratepick__clear" id="fRateClear">clear</button>
          </div>
        </div>
        <div class="field" id="priorWrap">
          <label>Viewing history</label>
          <label class="toggle"><input type="checkbox" id="fPrior"/><span class="toggle__track"></span><span class="toggle__label">I'd seen this before this log</span></label>
        </div>
      </div>

      <div class="field" id="datesWrap">
        <label>Watch dates</label>
        <div class="datechips" id="fDates"></div>
        <div class="field-hint">Add one date per viewing — re-watches welcome.</div>
      </div>

      <div class="field-row">
        <div class="field"><label>Release date</label><input class="input" id="fRelease" value="${g('ReleaseDate')}" placeholder="YYYY-MM-DD"/></div>
        <div class="field"><label>Runtime</label><input class="input" id="fRuntime" value="${g('Runtime')}" placeholder="HH:MM:SS"/></div>
      </div>
      <div class="field-row">
        <div class="field"><label>Director</label><input class="input" id="fDirector" value="${g('Director')}" placeholder="Director"/></div>
        <div class="field"><label>Studio</label><input class="input" id="fStudio" value="${g('Studio')}" placeholder="Studio"/></div>
      </div>
      <div class="field"><label>Genre</label><input class="input" id="fGenre" value="${g('Genre')}" placeholder="Genre1, Genre2"/></div>
      <div class="field"><label>Cast</label><input class="input" id="fActors" value="${g('Actors')}" placeholder="Actor 1, Actor 2"/></div>
      <div class="field"><label>Notes</label><textarea id="fNotes" placeholder="Your verdict…">${g('Notes')}</textarea></div>
    </div>
    <div class="modal__foot">
      <span class="spacer"></span>
      <button class="btn btn--ghost" id="mCancel">Cancel</button>
      <button class="btn btn--amber" id="mSave">${icon('check')}<span>${isNew ? 'Add to archive' : 'Save changes'}</span></button>
    </div>`;

  // status
  const paintStatus = () => { $$('#fStatus .statuspick__opt').forEach((o) => o.classList.toggle('is-active', o.dataset.v === modalState.status));
    $('#datesWrap').style.display = modalState.status === 'want_to_watch' ? 'none' : '';
    $('#priorWrap').style.display = modalState.status === 'want_to_watch' ? 'none' : ''; };
  $$('#fStatus .statuspick__opt').forEach((o) => o.onclick = () => { modalState.status = o.dataset.v; paintStatus(); });
  paintStatus();

  // rating
  const rp = $('#fRating');
  const paintRate = (v) => $$('.ratepick__star', rp).forEach((s) => s.classList.toggle('on', +s.dataset.n <= v));
  $$('.ratepick__star', rp).forEach((s) => {
    s.onmouseenter = () => { rp.classList.add('hot'); $$('.ratepick__star', rp).forEach((x) => x.classList.toggle('lit', +x.dataset.n <= +s.dataset.n)); };
    s.onclick = () => { modalState.rating = +s.dataset.n; paintRate(modalState.rating); };
  });
  rp.onmouseleave = () => { rp.classList.remove('hot'); $$('.ratepick__star', rp).forEach((x) => x.classList.remove('lit')); };
  $('#fRateClear').onclick = () => { modalState.rating = null; paintRate(0); };
  paintRate(modalState.rating || 0);

  // prior toggle
  $('#fPrior').checked = modalState.prior === true;
  $('#fPrior').onchange = (e) => modalState.prior = e.target.checked;

  // dates
  renderDateChips();

  // fetch
  $('#fFetch').onclick = doITunes;
  $('#fTitle').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); doITunes(); } });

  // buttons
  $('#mClose').onclick = closeModal;
  $('#mCancel').onclick = closeModal;
  $('#mSave').onclick = saveMovie;

  $('#scrim').hidden = false;
  requestAnimationFrame(() => { $('#scrim').classList.add('is-open'); $('#modal').classList.add('is-open'); });
  $('#modal').setAttribute('aria-hidden', 'false');
  setTimeout(() => $('#fTitle').focus(), 80);
}

function renderDateChips() {
  const box = $('#fDates');
  box.innerHTML = modalState.dates.map((d, i) =>
    `<span class="datechip">${esc(d)}<button data-i="${i}">${icon('x')}</button></span>`).join('') +
    `<span class="dateadd"><input class="input" id="fDateInput" placeholder="YYYY-MM-DD"/><button class="btn btn--ghost btn--sm" id="fDateToday">Today</button></span>`;
  $$('#fDates .datechip button').forEach((b) => b.onclick = () => { modalState.dates.splice(+b.dataset.i, 1); renderDateChips(); });
  const add = (v) => {
    v = (v || '').trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) { toast('Use YYYY-MM-DD format', 'err'); return; }
    if (!modalState.dates.includes(v)) modalState.dates.push(v);
    modalState.dates.sort(); renderDateChips(); $('#fDateInput').focus();
  };
  $('#fDateToday').onclick = () => add(new Date().toISOString().slice(0, 10));
  $('#fDateInput').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(e.target.value); } });
}

async function doITunes() {
  const term = $('#fTitle').value.trim();
  if (!term) { toast('Enter a title first', 'err'); return; }
  const box = $('#itunesBox');
  box.innerHTML = `<div class="itunes-results" style="padding:16px;display:flex;align-items:center;gap:10px;color:var(--paper-dim)"><span class="spinner"></span> Searching the catalogue…</div>`;
  try {
    let results;
    if (LOCAL_SERVER) {
      results = await api(`/api/itunes?term=${encodeURIComponent(term)}`);
    } else {
      const res = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(term)}&country=US&entity=movie&limit=8`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      results = (data.results || []).map((m) => {
        let rt = '';
        if (m.trackTimeMillis) {
          const ts = Math.round(m.trackTimeMillis / 1000);
          const h = Math.floor(ts / 3600), mm = Math.floor((ts % 3600) / 60), ss = ts % 60;
          rt = `${String(h).padStart(2,'0')}:${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
        }
        return {
          title: String(m.trackName || ''),
          year: m.releaseDate ? m.releaseDate.substring(0, 4) : '',
          releaseDate: m.releaseDate ? m.releaseDate.substring(0, 10) : '',
          runtime: rt,
          genre: String(m.primaryGenreName || ''),
          director: String(m.directorName || m.artistName || ''),
          poster: m.artworkUrl100 ? m.artworkUrl100.replace(/\d+x\d+bb/, '600x600bb') : null,
          notes: String(m.longDescription || ''),
        };
      });
    }
    if (!results || !results.length) { box.innerHTML = `<div class="field-hint" style="margin-top:8px">No online matches — fill the details by hand (the API may be unavailable).</div>`; return; }
    box.innerHTML = `<div class="itunes-results">${results.map((m, i) => `
      <div class="itunes-row" data-i="${i}">
        ${m.poster ? `<img src="${esc(m.poster)}" alt="">` : '<div style="width:38px;height:56px;border-radius:4px;background:var(--ink-3)"></div>'}
        <div><div class="ir-t">${esc(m.title)}</div><div class="ir-m">${[m.year, m.director, m.genre].filter(Boolean).map(esc).join(' · ')}</div></div>
      </div>`).join('')}</div>`;
    $$('#itunesBox .itunes-row').forEach((row) => row.onclick = () => {
      const m = results[+row.dataset.i];
      if (m.releaseDate) $('#fRelease').value = m.releaseDate;
      if (m.runtime) $('#fRuntime').value = m.runtime;
      if (m.genre) $('#fGenre').value = m.genre;
      if (m.director) $('#fDirector').value = m.director;
      if (m.notes && !$('#fNotes').value) $('#fNotes').value = m.notes;
      if (!$('#fTitle').value) $('#fTitle').value = m.title;
      box.innerHTML = `<div class="field-hint" style="margin-top:8px;color:var(--amber)">${icon('check')} Metadata filled from “${esc(m.title)}”.</div>`;
    });
  } catch (e) {
    box.innerHTML = `<div class="field-hint" style="margin-top:8px">Lookup unavailable — ${esc(e.message)}</div>`;
  }
}

async function saveMovie() {
  if (!LOCAL_SERVER) { toast('Editing is read-only in the published archive', 'info'); return; }
  const rec = {
    Title: $('#fTitle').value.trim(),
    Rating: modalState.rating,
    WatchDate: modalState.status === 'want_to_watch' ? [] : modalState.dates,
    Status: modalState.status,
    PriorWatch: modalState.status === 'want_to_watch' ? null : modalState.prior,
    ReleaseDate: $('#fRelease').value.trim(),
    Runtime: $('#fRuntime').value.trim(),
    Genre: $('#fGenre').value.trim(),
    Director: $('#fDirector').value.trim(),
    Studio: $('#fStudio').value.trim(),
    Actors: $('#fActors').value.trim(),
    Notes: $('#fNotes').value,
  };
  if (!rec.Title) { toast('A title is required', 'err'); $('#fTitle').focus(); return; }
  try {
    if (modalState.isNew) {
      await api('/api/movies', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(rec) });
      toast(`Added to the archive — ${rec.Title}`, 'ok');
    } else {
      await api(`/api/movies/${modalState.idx}`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(rec) });
      toast(`Record updated — ${rec.Title}`, 'ok');
    }
    closeModal();
    await reloadAndRender();
  } catch (e) { toast(e.message, 'err'); }
}

function closeModal() {
  $('#modal').classList.remove('is-open');
  $('#modal').setAttribute('aria-hidden', 'true');
  setTimeout(() => { if (!$('#drawer').classList.contains('is-open')) { $('#scrim').classList.remove('is-open'); $('#scrim').hidden = true; } }, 420);
}

/* ════════════════════════════════════════════════════════════════════════
   MISC ACTIONS
   ════════════════════════════════════════════════════════════════════════ */
async function exportLLM() {
  try {
    let text, count;
    if (LOCAL_SERVER) {
      const res = await api('/api/export/llm');
      text = res.text; count = res.count;
    } else {
      const min = state.records.map((r) => ({
        Title: r.Title, ReleaseDate: r.ReleaseDate, WatchDate: r.WatchDate,
        Status: r.Status, PriorWatch: r.PriorWatch, Rating: r.Rating, Notes: r.Notes,
      }));
      text = JSON.stringify({ _metadata: state.db._metadata, log: min }, null, 2);
      count = min.length;
    }
    await navigator.clipboard.writeText(text);
    toast(`Copied ${count} records + command reference for your LLM`, 'ok');
  } catch (e) {
    toast(`Copy failed — ${e.message}`, 'err');
  }
}

function surprise() {
  const pool = state.records.filter((r) => r.Status === 'want_to_watch');
  const fallback = state.records.filter((r) => r.Status !== 'want_to_watch' && !r.Rating);
  const list = pool.length ? pool : (fallback.length ? fallback : state.records);
  if (!list.length) return;
  const pick = list[Math.floor(Math.random() * list.length)];
  toast(pool.length ? "Tonight's feature presentation…" : 'How about a verdict on this one?', 'info');
  openDrawer(pick);
}

async function closeRoom() {
  if (!LOCAL_SERVER) return;
  if (!confirm('Close the projection room? This stops the local server.')) return;
  try { await api('/api/shutdown', { method: 'POST' }); } catch (_) {}
  document.body.innerHTML = `<div style="height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;text-align:center;font-family:var(--display)">
    <svg width="48" height="48" viewBox="0 0 24 24" style="color:var(--amber-deep)"><use href="#ic-reel"/></svg>
    <div style="font-size:34px;color:var(--paper)">The house lights are up.</div>
    <div style="font-family:var(--ui);color:var(--paper-faint);font-size:14px">The projection room has closed. You may shut this tab.</div></div>`;
}

/* ── toasts ───────────────────────────────────────────────────────────── */
let toastTimer;
function toast(msg, type = 'ok') {
  const ic = type === 'err' ? 'x' : type === 'info' ? 'sparkle' : 'check';
  const el = document.createElement('div');
  el.className = `toast toast--${type}`;
  el.innerHTML = `${icon(ic)}<span>${esc(msg)}</span>`;
  $('#toasts').appendChild(el);
  setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 360); }, 3200);
}

/* ════════════════════════════════════════════════════════════════════════
   EVENTS + INIT
   ════════════════════════════════════════════════════════════════════════ */
function wireGlobal() {
  $('#goHome').onclick = () => setView('dashboard');
  $('#goHome').onkeydown = (e) => { if (e.key === 'Enter') setView('dashboard'); };
  $$('.navtab').forEach((t) => t.onclick = () => setView(t.dataset.go));
  $('#btnAdd').onclick = () => openModal();
  $('#btnExport').onclick = exportLLM;
  $('#btnSurprise').onclick = surprise;
  $('#btnClose').onclick = closeRoom;
  if (!LOCAL_SERVER) {
    $('#btnAdd').hidden = true;
    $('#btnClose').hidden = true;
  }
  $('#btnSearch').onclick = () => { setView('library'); setTimeout(() => $('#searchInput').focus(), 60); };

  // search
  const si = $('#searchInput');
  si.addEventListener('input', () => { state.filters.search = si.value; $('#searchClear').hidden = !si.value; renderLibrary(); });
  $('#searchClear').onclick = () => { state.filters.search = ''; si.value = ''; $('#searchClear').hidden = true; si.focus(); renderLibrary(); };

  // status seg
  $$('#statusSeg .seg__btn').forEach((b) => b.onclick = () => { state.filters.status = b.dataset.status; syncFilterUI(); renderLibrary(); });

  // sort
  $('#sortSelect').onchange = (e) => { state.sort = e.target.value; renderLibrary(); };

  // filters toggle
  $('#btnFilters').onclick = () => { const f = $('#filterbar'); f.hidden = !f.hidden; };
  $('#btnClearFilters').onclick = () => {
    state.filters.genres.clear(); state.filters.minRating = 0; state.filters.decade = null;
    syncFilterUI(); renderLibrary();
  };

  // view toggle
  $$('#viewToggle .viewtoggle__btn').forEach((b) => b.onclick = () => {
    state.mode = b.dataset.mode;
    $$('#viewToggle .viewtoggle__btn').forEach((x) => x.classList.toggle('is-active', x === b));
    renderLibrary();
  });

  // ledger header sort
  $$('.ledger th.sortable').forEach((th) => th.onclick = () => {
    const map = { title: 'title-asc', year: 'year-desc', rating: 'rating-desc', runtime: 'runtime-desc', watch: 'watch-desc' };
    state.sort = map[th.dataset.sort] || state.sort;
    $$('.ledger th.sortable').forEach((x) => x.removeAttribute('data-dir'));
    th.setAttribute('data-dir', state.sort.endsWith('asc') ? 'asc' : 'desc');
    renderLibrary();
  });

  // scrim closes overlays
  $('#scrim').onclick = () => { closeDrawer(); closeModal(); };

  // keyboard
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { closeDrawer(); closeModal(); return; }
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
    if (typing) return;
    if (e.key === '/') { e.preventDefault(); setView('library'); setTimeout(() => $('#searchInput').focus(), 60); }
    else if (e.key === 'n') { e.preventDefault(); openModal(); }
    else if (e.key === 'd') setView('dashboard');
    else if (e.key === 'l') setView('library');
    else if (e.key === 'r') surprise();
    else if (e.key === 'g' && state.view === 'library') {
      state.mode = state.mode === 'wall' ? 'list' : 'wall';
      $$('#viewToggle .viewtoggle__btn').forEach((x) => x.classList.toggle('is-active', x.dataset.mode === state.mode));
      renderLibrary();
    }
  });
}

async function init() {
  wireGlobal();
  try {
    await loadDb();
    render();
  } catch (e) {
    $('.stage').innerHTML = `<div class="empty-state"><p class="empty-title">Couldn't reach the projector.</p><p class="empty-sub">${esc(e.message)}</p></div>`;
  }
}

document.addEventListener('DOMContentLoaded', init);
