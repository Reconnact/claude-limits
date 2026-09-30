(function (root) {
  const SAME_WINDOW = 60;   // resets_at moves by a few seconds between responses, a new window by hours
  const STALE = 30 * 60;
  const DAY = 24 * 3600;
  const GAP = DAY;
  const KEYS = ['five_hour', 'seven_day', 'fable'];
  const LENGTH = { five_hour: 5 * 3600, seven_day: 7 * DAY, fable: 7 * DAY };
  // $ per million tokens: input, output, cache read. A cache write costs 1.25× input for 5 min, 2× for 1 h; fast mode doubles all of it.
  const PRICES = {
    'claude-fable-5-1': [10, 50, 0.25],
    'claude-fable-5': [10, 50, 1],
    'claude-opus-5-5': [4, 20, 0.2],
    'claude-opus-5': [5, 25, 0.5],
    'claude-opus-4-8': [5, 25, 0.5],
    'claude-opus-4-7': [5, 25, 0.5],
    'claude-sonnet-5-5': [2, 10, 0.2],
    'claude-sonnet-5': [2, 10, 0.2],
    'claude-haiku-4-5': [1, 5, 0.1],
  };

  // One point per rise: both accounts report the same number, and an idle session repeats an old one.
  function points(S, key) {
    const out = [];
    let last = null;
    for (const s of S.filter(s => s[key]).sort((a, b) => a.ts - b.ts)) {
      const w = s[key];
      const same = last && Math.abs(w.resets_at - last.resets_at) <= SAME_WINDOW;
      if (last && (same ? w.used_percentage <= last.pct : w.resets_at < last.resets_at)) continue;
      last = { t: s.ts, pct: w.used_percentage, resets_at: same ? last.resets_at : w.resets_at };
      out.push(last);
    }
    return out;
  }

  function current(S, now) {
    if (!S.length) return null;
    const newest = S.reduce((a, b) => (b.ts > a.ts ? b : a));
    const win = key => {
      const p = points(S, key).pop();
      if (!p) return null;
      if (p.resets_at <= now) return { pct: 0, resets_at: null, reset: true };
      return { pct: p.pct, resets_at: p.resets_at, reset: false };
    };
    return {
      five_hour: win('five_hour'),
      seven_day: win('seven_day'),
      fable: win('fable'),
      ts: newest.ts,
      source: newest.source,
      stale: now - newest.ts > STALE,
    };
  }

  // One line per stretch of snapshots: more than a day without one is no data, not 0 %, and so is the time before the window's first point.
  function segments(S, key, from, to) {
    const steps = [];
    const pts = points(S, key);
    pts.forEach((p, i) => {
      steps.push({ t: p.t, pct: p.pct });
      const next = pts[i + 1];
      const ends = !next || next.resets_at !== p.resets_at;
      if (ends && p.resets_at <= to && (!next || p.resets_at <= next.t)) steps.push({ t: p.resets_at, pct: 0 });
    });
    const at = t => (steps.filter(p => p.t <= t).pop() || { pct: 0 }).pct;

    const spans = [];
    const first = pts.length ? pts[0].t : Infinity;
    for (const t of S.map(s => s.ts).filter(t => t >= first && t <= to).sort((a, b) => a - b)) {
      const last = spans[spans.length - 1];
      if (last && t - last[1] <= GAP) last[1] = t;
      else spans.push([t, t]);
    }
    const last = spans[spans.length - 1];
    if (last && to - last[1] <= GAP) last[1] = to;

    return spans.filter(([, end]) => end >= from).map(([start, end]) => {
      start = Math.max(start, from);
      return [{ t: start, pct: at(start) }, ...steps.filter(p => p.t > start && p.t <= end), { t: end, pct: at(end) }];
    });
  }

  // The part of a stepped line between a and b.
  function clip(line, a, b) {
    const start = Math.max(a, line[0].t), end = Math.min(b, line[line.length - 1].t);
    if (start >= end) return [];
    const at = t => line.filter(p => p.t <= t).pop().pct;
    return [{ t: start, pct: at(start) }, ...line.filter(p => p.t > start && p.t < end), { t: end, pct: at(end) }];
  }

  // Each window runs from its reset minus its length to its reset, as high as its peak; its fill is the line inside it.
  function windows(S, key, from, to) {
    const lines = segments(S, key, from, to), pts = points(S, key);
    return [...new Set(pts.map(p => p.resets_at))]
      .map(end => ({ start: end - LENGTH[key], end, peak: Math.max(...pts.filter(p => p.resets_at === end).map(p => p.pct)) }))
      .filter(w => w.end > from && w.start < to)
      .map(w => ({ ...w, fill: lines.map(line => clip(line, w.start, w.end)).filter(l => l.length) }));
  }

  function path(line, from, to, w, h) {
    const r = v => Math.round(v * 10) / 10;
    const x = t => r((t - from) / (to - from) * w);
    const y = pct => r(h - pct / 100 * h);
    return line.map((p, i) => (i ? `H${x(p.t)}V${y(p.pct)}` : `M${x(p.t)} ${y(p.pct)}`)).join('');
  }

  function until(t, now) {
    const min = Math.ceil((t - now) / 60);
    const d = Math.floor(min / 1440), h = Math.floor(min % 1440 / 60), m = min % 60;
    const parts = d ? [[d, 'd'], [h, 'h']] : h ? [[h, 'h'], [m, 'min']] : [[m, 'min']];
    return parts.filter(([n], i) => n || !i).map(([n, unit]) => `${n} ${unit}`).join(' ');
  }

  function cost(r) {
    const p = PRICES[r.model.replace(/-\d{8}$/, '')];
    if (!p) return null;
    const [input, output, read] = p;
    return (r.speed === 'fast' ? 2 : 1) * (r.input * input + r.cache_write_5m * input * 1.25 + r.cache_write_1h * input * 2 + r.cache_read * read + r.output * output) / 1e6;
  }

  // Rows are hours, so an hour that overlaps the range counts whole.
  function projects(T, from, to) {
    const by = {}, unpriced = new Set();
    for (const r of T.filter(r => r.hour + 3600 > from && r.hour <= to)) {
      const p = by[r.project] ||= { project: r.project, tokens: 0, cost: 0 };
      p.tokens += r.input + r.cache_write_5m + r.cache_write_1h + r.cache_read + r.output;
      const c = cost(r);
      if (c === null) unpriced.add(r.model);
      else p.cost += c;
    }
    return { rows: Object.values(by).sort((a, b) => b.cost - a.cost || b.tokens - a.tokens), unpriced: [...unpriced].sort() };
  }

  function tokens(n) {
    for (const [div, unit] of [[1e9, 'B'], [1e6, 'M'], [1e3, 'k']]) {
      if (n >= div) return `${(n / div).toFixed(n >= div * 100 ? 0 : 1)} ${unit}`;
    }
    return String(n);
  }

  function dollars(n) {
    return `$${n.toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }

  function renderProjects(doc, T, from, now) {
    const { rows, unpriced } = projects(T, from, now);
    const cells = (...values) => {
      const tr = doc.createElement('tr');
      values.forEach((v, i) => { const td = doc.createElement(i ? 'td' : 'th'); td.textContent = v; tr.append(td); });
      return tr;
    };
    doc.querySelector('#projects tbody').replaceChildren(...rows.map(r => cells(r.project, tokens(r.tokens), dollars(r.cost))));
    const sum = k => rows.reduce((t, r) => t + r[k], 0);
    doc.querySelector('#projects tfoot').replaceChildren(cells('Total', tokens(sum('tokens')), dollars(sum('cost'))));
    doc.getElementById('projects').hidden = !rows.length;
    doc.getElementById('unpriced').textContent = unpriced.length ? `No price for ${unpriced.join(', ')}` : '';
  }

  function render(doc, S, now, days, T = []) {
    const main = doc.querySelector('main');
    const c = current(S, now);
    if (!c) {
      main.classList.add('empty');
      doc.getElementById('asof').textContent = 'no snapshots yet';
      return;
    }
    main.classList.toggle('stale', c.stale);

    for (const key of KEYS) {
      const el = doc.getElementById(key), w = c[key];
      el.querySelector('.pct').textContent = w ? `${Math.round(w.pct)} %` : '–';
      el.querySelector('.reset').textContent = !w ? '' : w.reset ? 'reset' : `resets in ${until(w.resets_at, now).replace(/ /g, '\u00a0')}`;
      el.querySelector('.bar i').style.width = `${w ? Math.min(w.pct, 100) : 0}%`;
      el.classList.toggle('warn', !!w && w.pct >= 80);
    }

    const from = days === 'all' ? S.reduce((t, s) => Math.min(t, s.ts), now - DAY) : now - days * DAY;
    renderProjects(doc, T, days === 'all' ? T.reduce((t, r) => Math.min(t, r.hour), from) : from, now);
    for (const key of KEYS) {
      const d = segments(S, key, from, now).map(line => path(line, from, now, 700, 160)).join('');
      doc.getElementById(`line-${key}`).setAttribute('d', d);
    }

    const framed = days === 'all' || days > 7 ? 'seven_day' : 'five_hour';
    // over weeks the 5 h line is noise under the weekly frames
    if (framed === 'seven_day') doc.getElementById('line-five_hour').setAttribute('d', '');
    const frames = doc.getElementById('frames');
    const x = t => Math.round((t - from) / (now - from) * 7000) / 10;
    const el = (name, attrs) => {
      const e = doc.createElementNS('http://www.w3.org/2000/svg', name);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      return e;
    };
    frames.setAttribute('class', framed);
    frames.replaceChildren(...windows(S, framed, from, now).flatMap(w => [
      ...w.fill.map(line => el('path', { class: 'fill', d: `${path(line, from, now, 700, 160)}V160H${x(line[0].t)}Z` })),
      el('rect', { class: 'frame', x: x(Math.max(w.start, from)), y: 160 - Math.min(w.peak, 100) * 1.6, width: x(Math.min(w.end, now)) - x(Math.max(w.start, from)), height: Math.min(w.peak, 100) * 1.6 }),
    ]));

    const labels = doc.getElementById('days');
    const span = (now - from) / DAY;
    // a day or less gets hour ticks, anything longer day ticks
    const hours = span <= 0.25 ? 1 : span <= 1 ? 3 : 0;
    const first = new Date(now * 1000);
    if (hours) first.setHours(first.getHours() - first.getHours() % hours, 0, 0, 0);
    else first.setHours(0, 0, 0, 0);
    const step = hours ? hours * 3600 : DAY;
    const every = hours ? 1 : Math.ceil(span / 7);
    const format = hours ? t => t.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
      : span <= 7 ? t => t.toLocaleDateString('en', { weekday: 'short' })
      : t => t.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
    labels.replaceChildren();
    for (let t = first / 1000, i = 0; t > from; t -= step, i++) {
      const left = (t - from) / (now - from) * 100;
      if (i % every || left > 90) continue;
      const label = doc.createElement('span');
      label.style.left = `${left}%`;
      label.textContent = format(new Date(t * 1000));
      labels.append(label);
    }

    const at = new Date(c.ts * 1000).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    const age = c.stale ? ` · ${until(now, c.ts)} ago` : '';
    doc.getElementById('asof').textContent = `as of ${at} · ${c.source}${age}`;
  }

  root.Limits = { points, current, segments, clip, windows, path, until, cost, projects, tokens, dollars, render };
  if (typeof module !== 'undefined') module.exports = root.Limits;
})(typeof window !== 'undefined' ? window : globalThis);
