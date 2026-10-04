(function (root) {
  const SAME_WINDOW = 60;   // resets_at moves by a few seconds between responses, a new window by hours
  const STALE = 30 * 60;
  const DAY = 24 * 3600;
  const RATE_SPAN = { five_hour: 3600, seven_day: DAY, fable: DAY };   // the pace is the rise over the last hour, over the last day for the weekly limits
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
      return { pct: p.pct, resets_at: p.resets_at, reset: false, elapsed: Math.min(1, Math.max(0, (now - (p.resets_at - LENGTH[key])) / LENGTH[key])) };
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

  // The rise over the span in % per hour, counted across a reset from each window's held value; before a window's first
  // snapshot nothing is known, so the span starts at the first snapshot it meets. And when the current window reaches 100 %
  // at that rate, if that comes before its reset.
  function pace(S, key, now) {
    const pts = points(S, key);
    const last = pts[pts.length - 1];
    if (!last || last.resets_at <= now) return null;
    const windows = byWindow(pts).filter(w => w.end > now - RATE_SPAN[key]);
    const since = Math.max(now - RATE_SPAN[key], Math.min(...windows.map(w => w.own[0].t)));
    if (since >= now) return null;
    const rise = windows.reduce((sum, { end, own }) => {
      const at = t => own.filter(p => p.t <= t).map(p => p.pct).pop() || 0;
      return sum + at(Math.min(now, end)) - at(since);
    }, 0);
    const rate = rise / (now - since) * 3600;
    const full = rate > 0 ? now + (100 - last.pct) / rate * 3600 : null;
    return { rate, full: full !== null && full < last.resets_at ? full : null };
  }

  function paceText(p, now, key) {
    if (!p) return '';
    const rate = key === 'five_hour' ? `${p.rate.toFixed(1)} %/h` : `${Math.round(p.rate * 24)} %/d`;
    return p.full ? `at this pace full ${clock(p.full, now)} · ${rate}` : rate;
  }

  // points() keeps a window's points together, so one pass splits them.
  function byWindow(pts) {
    const out = [];
    for (let i = 0; i < pts.length;) {
      let j = i;
      while (j < pts.length && pts[j].resets_at === pts[i].resets_at) j++;
      let n = j;
      while (n < pts.length && pts[n].t <= pts[j - 1].t) n++;
      out.push({ end: pts[i].resets_at, own: pts.slice(i, j), next: pts[n] });
      i = j;
    }
    return out;
  }

  // One line per window, from its first point to its reset: snapshots come only with Claude Code turns, so a gap is idle time and the value holds.
  function segments(S, key, from, to) {
    return byWindow(points(S, key)).map(({ end, own, next }) => {
      const last = own[own.length - 1];
      return clip([...own.map(p => ({ t: p.t, pct: p.pct })), { t: Math.min(end, next ? next.t : end), pct: last.pct }], from, to);
    }).filter(line => line.length);
  }

  // Where the pace takes the current window from now: to 100 % where it hits, else to the reset, cut at the chart's end.
  function projection(S, key, now, to) {
    const p = pace(S, key, now);
    if (!p) return [];
    const last = points(S, key).pop();
    const end = Math.min(p.full || last.resets_at, to);
    return [{ t: now, pct: last.pct }, { t: end, pct: last.pct + p.rate * (end - now) / 3600 }];
  }

  // The part of a stepped line between a and b.
  function clip(line, a, b) {
    const start = Math.max(a, line[0].t), end = Math.min(b, line[line.length - 1].t);
    if (start >= end) return [];
    const at = t => line.filter(p => p.t <= t).pop().pct;
    return [{ t: start, pct: at(start) }, ...line.filter(p => p.t > start && p.t < end), { t: end, pct: at(end) }];
  }

  // Each window runs from its reset minus its length to its reset, as high as its peak; its fill is the line inside it, up to now.
  function windows(S, key, from, to, now = to) {
    const lines = segments(S, key, from, now);
    return byWindow(points(S, key))
      .map(({ end, own }) => ({ start: end - LENGTH[key], end, peak: Math.max(...own.map(p => p.pct)) }))
      .filter(w => w.end > from && w.start < to)
      .map(w => ({ ...w, fill: lines.map(line => clip(line, w.start, w.end)).filter(l => l.length) }));
  }

  function path(line, from, to, w, h, stepped = true) {
    const r = v => Math.round(v * 10) / 10;
    const x = t => r((t - from) / (to - from) * w);
    const y = pct => r(h - pct / 100 * h);
    return line.map((p, i) => (!i ? `M${x(p.t)} ${y(p.pct)}` : stepped ? `H${x(p.t)}V${y(p.pct)}` : `L${x(p.t)} ${y(p.pct)}`)).join('');
  }

  function until(t, now) {
    const min = Math.ceil((t - now) / 60);
    const d = Math.floor(min / 1440), h = Math.floor(min % 1440 / 60), m = min % 60;
    const parts = d ? [[d, 'd'], [h, 'h']] : h ? [[h, 'h'], [m, 'min']] : [[m, 'min']];
    return parts.filter(([n], i) => n || !i).map(([n, unit]) => `${n} ${unit}`).join(' ');
  }

  function clock(t, now) {
    const d = new Date(t * 1000), pad = n => String(n).padStart(2, '0');
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    return d.toDateString() === new Date(now * 1000).toDateString() ? time : `${d.toLocaleDateString('en-US', { weekday: 'short' })} ${time}`;
  }

  function resets(t, now, format = 'countdown') {
    const left = `in ${until(t, now)}`;
    return `resets ${format === 'time' ? clock(t, now) : format === 'both' ? `${clock(t, now)} · ${left}` : left}`;
  }

  function cost(r) {
    const p = PRICES[r.model.replace(/-\d{8}$/, '')];
    if (!p) return null;
    const [input, output, read] = p;
    return (r.speed === 'fast' ? 2 : 1) * (r.input * input + r.cache_write_5m * input * 1.25 + r.cache_write_1h * input * 2 + r.cache_read * read + r.output * output) / 1e6;
  }

  // The table's row name per split: a folder, an agent, a session by its title or else its folder, the entrypoint of the run, the machine.
  const SPLITS = {
    folder: r => r.project,
    agent: r => r.agent || 'main session',
    session: r => r.title || r.project,
    source: r => r.entry || '?',
    machine: r => r.host || '?',
  };

  // Rows are hours, so an hour that overlaps the range counts whole.
  function projects(T, from, to, split = 'folder') {
    const by = {}, unpriced = new Set(), name = SPLITS[split];
    for (const r of T.filter(r => r.hour + 3600 > from && r.hour <= to)) {
      const p = by[name(r)] ||= { name: name(r), tokens: 0, cost: 0 };
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

  function renderProjects(doc, T, from, now, split) {
    const { rows, unpriced } = projects(T, from, now, split);
    const cells = (...values) => {
      const tr = doc.createElement('tr');
      values.forEach((v, i) => { const td = doc.createElement(i ? 'td' : 'th'); td.textContent = v; tr.append(td); });
      return tr;
    };
    doc.querySelector('#projects thead th').textContent = split[0].toUpperCase() + split.slice(1);
    doc.querySelector('#projects tbody').replaceChildren(...rows.map(r => cells(r.name, tokens(r.tokens), dollars(r.cost))));
    const sum = k => rows.reduce((t, r) => t + r[k], 0);
    doc.querySelector('#projects tfoot').replaceChildren(cells('Total', tokens(sum('tokens')), dollars(sum('cost'))));
    for (const id of ['projects', 'split']) doc.getElementById(id).hidden = !rows.length;
    doc.getElementById('unpriced').textContent = unpriced.length ? `No price for ${unpriced.join(', ')}` : '';
  }

  function render(doc, S, now, days, T = [], resetFormat, line = 'steps', split = 'folder') {
    const stepped = line !== 'smooth';
    const main = doc.querySelector('main');
    const c = current(S, now);
    main.classList.toggle('empty', !c);
    if (!c) {
      doc.getElementById('asof').textContent = 'no snapshots yet';
      return;
    }
    main.classList.toggle('stale', c.stale);

    for (const key of KEYS) {
      const el = doc.getElementById(key), w = c[key];
      el.querySelector('.pct').textContent = w ? `${Math.round(w.pct)} %` : '–';
      el.querySelector('.reset').textContent = !w ? '' : w.reset ? 'reset'
        : resets(w.resets_at, now, resetFormat).replace(/(\d) /g, '$1\u00a0');
      el.querySelector('.bar i').style.width = `${w ? Math.min(w.pct, 100) : 0}%`;
      const tick = el.querySelector('.bar b');
      tick.hidden = !w || w.reset;
      tick.style.left = w && !w.reset ? `${w.elapsed * 100}%` : '';
      el.querySelector('.pace').textContent = paceText(pace(S, key, now), now, key).replace(/(\d) /g, '$1\u00a0');
    }

    const from = days === 'all' ? S.reduce((t, s) => Math.min(t, s.ts), now - DAY) : now - days * DAY;
    renderProjects(doc, T, days === 'all' ? T.reduce((t, r) => Math.min(t, r.hour), from) : from, now, split);
    const framed = days === 'all' || days > 7 ? 'seven_day' : 'five_hour';
    // the chart runs on to the framed window's reset, so its projection has room; a line marks now
    const to = Math.max(now, (c[framed] && c[framed].resets_at) || now);
    const x = t => Math.round((t - from) / (to - from) * 7000) / 10;
    const nowLine = doc.getElementById('now');
    nowLine.setAttribute('x1', x(now));
    nowLine.setAttribute('x2', x(now));
    nowLine.setAttribute('visibility', to > now ? 'visible' : 'hidden');
    // a framed line is its fill's top edge, and over weeks the 5 h line is noise under the weekly frames
    for (const key of KEYS.filter(k => k !== 'five_hour')) {
      const d = key === framed ? '' : segments(S, key, from, now).map(l => path(l, from, to, 700, 160, stepped)).join('');
      doc.getElementById(`line-${key}`).setAttribute('d', d);
    }
    for (const key of KEYS)
      doc.getElementById(`proj-${key}`).setAttribute('d', key === 'five_hour' && framed !== key ? '' : path(projection(S, key, now, to), from, to, 700, 160, false));
    const frames = doc.getElementById('frames');
    const el = (name, attrs) => {
      const e = doc.createElementNS('http://www.w3.org/2000/svg', name);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      return e;
    };
    frames.setAttribute('class', framed);
    frames.replaceChildren(...windows(S, framed, from, to, now).flatMap(w => [
      ...w.fill.map(l => el('path', { class: 'fill', d: `${path(l, from, to, 700, 160, stepped)}V160H${x(l[0].t)}Z` })),
      el('rect', { class: 'frame', x: x(Math.max(w.start, from)), y: 160 - Math.min(w.peak, 100) * 1.6, width: x(Math.min(w.end, to)) - x(Math.max(w.start, from)), height: Math.min(w.peak, 100) * 1.6 }),
    ]));

    const labels = doc.getElementById('days');
    const span = (to - from) / DAY;
    // a day or less gets hour ticks, anything longer day ticks
    const hours = span <= 0.25 ? 1 : span <= 1 ? 3 : 0;
    const first = new Date(to * 1000);
    if (hours) first.setHours(first.getHours() - first.getHours() % hours, 0, 0, 0);
    else first.setHours(0, 0, 0, 0);
    const step = hours ? hours * 3600 : DAY;
    const every = hours ? 1 : Math.ceil(span / 7);
    const format = hours ? t => t.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
      : span <= 7 ? t => t.toLocaleDateString('en', { weekday: 'short' })
      : t => t.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
    labels.replaceChildren();
    for (let t = first / 1000, i = 0; t > from; t -= step, i++) {
      const left = (t - from) / (to - from) * 100;
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

  root.Limits = { SPLITS, points, current, pace, paceText, projection, segments, clip, windows, path, until, resets, cost, projects, tokens, dollars, render };
  if (typeof module !== 'undefined') module.exports = root.Limits;
})(typeof window !== 'undefined' ? window : globalThis);
