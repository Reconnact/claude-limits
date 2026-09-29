(function (root) {
  const SAME_WINDOW = 60;   // resets_at moves by a few seconds between responses, a new window by hours
  const STALE = 30 * 60;
  const DAY = 24 * 3600;

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
      ts: newest.ts,
      source: newest.source,
      stale: now - newest.ts > STALE,
    };
  }

  function steps(S, key, from, to) {
    const all = [];
    const pts = points(S, key);
    pts.forEach((p, i) => {
      all.push({ t: p.t, pct: p.pct });
      const next = pts[i + 1];
      const ends = !next || next.resets_at !== p.resets_at;
      if (ends && p.resets_at <= to && (!next || p.resets_at <= next.t)) all.push({ t: p.resets_at, pct: 0 });
    });
    const before = all.filter(p => p.t < from).pop();
    const inside = all.filter(p => p.t >= from && p.t <= to);
    return before ? [{ t: from, pct: before.pct }, ...inside] : inside;
  }

  function path(steps, from, to, w, h) {
    if (!steps.length) return '';
    const r = v => Math.round(v * 10) / 10;
    const x = t => r((t - from) / (to - from) * w);
    const y = pct => r(h - pct / 100 * h);
    return steps.map((p, i) => (i ? `H${x(p.t)}V${y(p.pct)}` : `M${x(p.t)} ${y(p.pct)}`)).join('') + `H${w}`;
  }

  function until(t, now) {
    const min = Math.ceil((t - now) / 60);
    const d = Math.floor(min / 1440), h = Math.floor(min % 1440 / 60), m = min % 60;
    const parts = d ? [[d, 'd'], [h, 'h']] : h ? [[h, 'h'], [m, 'min']] : [[m, 'min']];
    return parts.filter(([n], i) => n || !i).map(([n, unit]) => `${n} ${unit}`).join(' ');
  }

  function render(doc, S, now) {
    const main = doc.querySelector('main');
    const c = current(S, now);
    if (!c) {
      main.classList.add('empty');
      doc.getElementById('asof').textContent = 'no snapshots yet';
      return;
    }
    main.classList.toggle('stale', c.stale);

    for (const key of ['five_hour', 'seven_day']) {
      const el = doc.getElementById(key), w = c[key];
      el.querySelector('.pct').textContent = w ? `${Math.round(w.pct)} %` : '–';
      el.querySelector('.reset').textContent = !w ? '' : w.reset ? 'reset' : `resets in ${until(w.resets_at, now)}`;
      el.querySelector('.bar i').style.width = `${w ? Math.min(w.pct, 100) : 0}%`;
      el.classList.toggle('warn', !!w && w.pct >= 80);
    }

    const from = now - 7 * DAY;
    for (const key of ['five_hour', 'seven_day']) {
      doc.getElementById(`line-${key}`).setAttribute('d', path(steps(S, key, from, now), from, now, 700, 160));
    }

    const days = doc.getElementById('days');
    const midnight = new Date(now * 1000);
    midnight.setHours(0, 0, 0, 0);
    for (let t = midnight / 1000; t > from; t -= DAY) {
      const left = (t - from) / (now - from) * 100;
      if (left > 94) continue;
      const label = doc.createElement('span');
      label.style.left = `${left}%`;
      label.textContent = new Date(t * 1000).toLocaleDateString('en', { weekday: 'short' });
      days.append(label);
    }

    const at = new Date(c.ts * 1000).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
    const age = c.stale ? ` · ${until(now, c.ts)} ago` : '';
    doc.getElementById('asof').textContent = `as of ${at} · ${c.source}${age}`;
  }

  root.Limits = { points, current, steps, path, until, render };
  if (typeof module !== 'undefined') module.exports = root.Limits;
})(typeof window !== 'undefined' ? window : globalThis);
