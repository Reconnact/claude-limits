const test = require('node:test');
const assert = require('node:assert/strict');
const Limits = require('../limits.js');

const H = 3600;
const DAY = 24 * H;
const T0 = 1790000000;

function snap(ts, source, h5, d7, fb) {
  return {
    ts, source,
    five_hour: h5 && { used_percentage: h5[0], resets_at: h5[1] },
    seven_day: d7 && { used_percentage: d7[0], resets_at: d7[1] },
    fable: fb && { used_percentage: fb[0], resets_at: fb[1] },
  };
}

test('points: sorted by time across both sources', () => {
  const S = [
    snap(T0 + 200, 'hw', [12, T0 + 5 * H], null),
    snap(T0 + 100, 'reconnact', [10, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.points(S, 'five_hour').map(p => [p.t, p.pct]), [[T0 + 100, 10], [T0 + 200, 12]]);
});

test('points: a lower percentage in the same window is dropped', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [20, T0 + 5 * H], null),
    snap(T0 + 200, 'hw', [15, T0 + 5 * H + 30], null),
    snap(T0 + 300, 'reconnact', [22, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.points(S, 'five_hour').map(p => p.pct), [20, 22]);
});

test('points: an older window after a newer one is dropped', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [5, T0 + 10 * H], null),
    snap(T0 + 200, 'hw', [90, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.points(S, 'five_hour').map(p => p.pct), [5]);
});

test('points: a new window starts low', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null),
    snap(T0 + 6 * H, 'reconnact', [3, T0 + 11 * H], null),
  ];
  assert.deepEqual(Limits.points(S, 'five_hour').map(p => p.pct), [80, 3]);
});

test('points: snapshots without the window are skipped', () => {
  const S = [snap(T0, 'hw', null, [40, T0 + 100 * H])];
  assert.deepEqual(Limits.points(S, 'five_hour'), []);
});

test('current: the latest value of each window', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [20, T0 + 5 * H], [40, T0 + 100 * H]),
    snap(T0 + 200, 'hw', [25, T0 + 5 * H], [41, T0 + 100 * H]),
  ];
  const c = Limits.current(S, T0 + 300);
  assert.equal(c.five_hour.pct, 25);
  assert.equal(c.five_hour.resets_at, T0 + 5 * H);
  assert.equal(c.five_hour.reset, false);
  assert.equal(c.seven_day.pct, 41);
  assert.equal(c.ts, T0 + 200);
  assert.equal(c.source, 'hw');
  assert.equal(c.stale, false);
});

test('current: a window past its reset time shows as reset', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], [40, T0 + 100 * H])];
  const c = Limits.current(S, T0 + 6 * H);
  assert.equal(c.five_hour.pct, 0);
  assert.equal(c.five_hour.reset, true);
  assert.equal(c.seven_day.pct, 40);
  assert.equal(c.seven_day.reset, false);
});

test('current: older than 30 min is stale', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], null)];
  assert.equal(Limits.current(S, T0 + 1800).stale, false);
  assert.equal(Limits.current(S, T0 + 1801).stale, true);
});

test('current: a check without values moves "as of", not the values', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], null), { ts: T0 + 1700, source: 'hw' }];
  const c = Limits.current(S, T0 + 1801);
  assert.equal(c.five_hour.pct, 80);
  assert.equal(c.ts, T0 + 1700);
  assert.equal(c.source, 'hw');
  assert.equal(c.stale, false);
});

test('current: no snapshots', () => {
  assert.equal(Limits.current([], T0), null);
});

test('current: a window that never came is null', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], null)];
  assert.equal(Limits.current(S, T0 + 10).seven_day, null);
});

test('current: the share of the window that has passed', () => {
  const S = [snap(T0 + H, 'hw', [20, T0 + 5 * H], [40, T0 + 7 * DAY])];
  const c = Limits.current(S, T0 + 2 * H);
  assert.equal(c.five_hour.elapsed, 0.4);
  assert.equal(c.seven_day.elapsed, 2 * H / (7 * DAY));
});

test('current: a reset window has no share', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], null)];
  assert.equal(Limits.current(S, T0 + 6 * H).five_hour.elapsed, undefined);
});

test('pace: the rise over the last hour, full before the reset', () => {
  const S = [
    snap(T0 + 30 * 60, 'hw', [10, T0 + 5 * H], null),
    snap(T0 + H, 'hw', [20, T0 + 5 * H], null),
    snap(T0 + 2 * H, 'hw', [60, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.pace(S, 'five_hour', T0 + 2 * H), { rate: 40, full: T0 + 3 * H });
});

test('pace: a slower rise reaches the reset first', () => {
  const S = [snap(T0 + H, 'hw', [5, T0 + 5 * H], null), snap(T0 + 2 * H, 'hw', [10, T0 + 5 * H], null)];
  assert.deepEqual(Limits.pace(S, 'five_hour', T0 + 2 * H), { rate: 5, full: null });
});

test('pace: nothing is known before a window\'s first snapshot, so the rise starts there', () => {
  const S = [snap(T0 + 90 * 60, 'hw', [30, T0 + 5 * H], null)];
  assert.deepEqual(Limits.pace(S, 'five_hour', T0 + 2 * H), { rate: 0, full: null });
});

test('pace: the rise counts across a reset, so a young window has one', () => {
  const S = [
    snap(T0 - 2 * H, 'hw', [40, T0], null),
    snap(T0 - 20 * 60, 'hw', [60, T0], null),
    snap(T0 + 20 * 60, 'hw', [10, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.pace(S, 'five_hour', T0 + 30 * 60), { rate: 30, full: T0 + 30 * 60 + 3 * H });
});

test('pace: the weekly limits take the rise over the last day, from the first snapshot in it', () => {
  const S = [snap(T0 - 20 * H, 'hw', null, [10, T0 + 3 * DAY]), snap(T0 - 2 * H, 'hw', null, [30, T0 + 3 * DAY]), snap(T0, 'hw', null, [40, T0 + 3 * DAY])];
  assert.deepEqual(Limits.pace(S, 'seven_day', T0), { rate: 1.5, full: T0 + (100 - 40) / 1.5 * 3600 });
});

test('pace: an idle stretch brings the rate down to 0', () => {
  const S = [snap(T0 + H, 'hw', [20, T0 + 5 * H], null)];
  assert.deepEqual(Limits.pace(S, 'five_hour', T0 + 3 * H), { rate: 0, full: null });
});

test('pace: an expired window has none', () => {
  const S = [snap(T0 + H, 'hw', [80, T0 + 5 * H], null)];
  assert.equal(Limits.pace(S, 'five_hour', T0 + 6 * H), null);
});

test('pace: the text under a limit, per hour or per day', () => {
  assert.equal(Limits.paceText(null, T0, 'five_hour'), '');
  assert.equal(Limits.paceText({ rate: 5, full: null }, T0, 'five_hour'), '5.0 %/h');
  assert.equal(Limits.paceText({ rate: 1.3, full: null }, T0, 'seven_day'), '31 %/d');
  assert.match(Limits.paceText({ rate: 40, full: T0 + 3 * H }, T0, 'five_hour'), /^at this pace full (\w{3} )?\d\d:\d\d · 40\.0 %\/h$/);
});

test('segments: the line ends where its window resets, the next window starts a new one', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null),
    snap(T0 + 6 * H, 'reconnact', [3, T0 + 11 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 7 * H), [
    [{ t: T0 + 100, pct: 80 }, { t: T0 + 5 * H, pct: 80 }],
    [{ t: T0 + 6 * H, pct: 3 }, { t: T0 + 7 * H, pct: 3 }],
  ]);
});

test('segments: a reset still ahead adds no drop', () => {
  const S = [snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null)];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + H), [[
    { t: T0 + 100, pct: 80 },
    { t: T0 + H, pct: 80 },
  ]]);
});

test('segments: the value before the range carries into it', () => {
  const S = [
    snap(T0 - 500, 'reconnact', [30, T0 + 5 * H], null),
    snap(T0 + 100, 'reconnact', [35, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + H), [[
    { t: T0, pct: 30 },
    { t: T0 + 100, pct: 35 },
    { t: T0 + H, pct: 35 },
  ]]);
});

test('segments: no snapshots, no line', () => {
  assert.deepEqual(Limits.segments([], 'five_hour', T0, T0 + H), []);
});

test('segments: days without a snapshot hold the value until the reset, then no line', () => {
  const S = [
    snap(T0, 'hw', [50, T0 + 5 * H], null),
    snap(T0 + 3 * DAY, 'hw', [10, T0 + 3 * DAY + 5 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0 - H, T0 + 3 * DAY + H), [
    [{ t: T0, pct: 50 }, { t: T0 + 5 * H, pct: 50 }],
    [{ t: T0 + 3 * DAY, pct: 10 }, { t: T0 + 3 * DAY + H, pct: 10 }],
  ]);
});

test('segments: snapshots that repeat a value keep the line going', () => {
  const week = [40, T0 + 100 * H];
  const S = [0, 12, 24, 36].map(h => snap(T0 + h * H, 'hw', null, week));
  assert.deepEqual(Limits.segments(S, 'seven_day', T0, T0 + 36 * H), [[
    { t: T0, pct: 40 },
    { t: T0 + 36 * H, pct: 40 },
  ]]);
});

test('segments: a snapshot without the window adds no line', () => {
  const S = [
    snap(T0, 'hw', [80, T0 + H], [40, T0 + 100 * H]),
    snap(T0 + 2 * H, 'hw', null, [40, T0 + 100 * H]),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 2 * H), [[
    { t: T0, pct: 80 },
    { t: T0 + H, pct: 80 },
  ]]);
});

test('segments: after the last snapshot the line runs on to its reset', () => {
  const S = [
    snap(T0, 'hw', [50, T0 + 5 * H], null),
    snap(T0 + H, 'hw', [60, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 3 * DAY), [[
    { t: T0, pct: 50 },
    { t: T0 + H, pct: 60 },
    { t: T0 + 5 * H, pct: 60 },
  ]]);
});

test('segments: a window that reset before the range has no line in it', () => {
  const S = [snap(T0, 'hw', [50, T0 + 5 * H], null)];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0 + 2 * DAY, T0 + 3 * DAY), []);
});

test('current: the fable window', () => {
  const S = [snap(T0, 'hw', [4, T0 + H], [69, T0 + 100 * H], [76, T0 + 100 * H])];
  const c = Limits.current(S, T0 + 10);
  assert.equal(c.fable.pct, 76);
  assert.equal(c.fable.resets_at, T0 + 100 * H);
});

test('segments: no line before the window\'s first point', () => {
  const S = [
    snap(T0, 'hw', [4, T0 + 5 * H], [60, T0 + 100 * H]),
    snap(T0 + H, 'hw', [5, T0 + 5 * H], [61, T0 + 100 * H], [76, T0 + 100 * H]),
    snap(T0 + 2 * H, 'hw', [6, T0 + 5 * H], [62, T0 + 100 * H]),
  ];
  assert.deepEqual(Limits.segments(S, 'fable', T0, T0 + 2 * H), [[
    { t: T0 + H, pct: 76 },
    { t: T0 + 2 * H, pct: 76 },
  ]]);
});

test('path: a step line scaled to the box', () => {
  const line = [{ t: 0, pct: 50 }, { t: 50, pct: 100 }, { t: 100, pct: 100 }];
  assert.equal(Limits.path(line, 0, 100, 200, 100), 'M0 50H100V0H200V0');
});

test('path: a smooth line goes straight from point to point', () => {
  const line = [{ t: 0, pct: 50 }, { t: 50, pct: 100 }, { t: 100, pct: 100 }];
  assert.equal(Limits.path(line, 0, 100, 200, 100, false), 'M0 50L100 0L200 0');
});

test('path: no points, no path', () => {
  assert.equal(Limits.path([], 0, 100, 200, 100), '');
});

test('resets: time left by default, the clock time or both from the settings', () => {
  assert.equal(Limits.resets(T0 + 90 * 60, T0), 'resets in 1 h 30 min');
  assert.equal(Limits.resets(T0 + 90 * 60, T0, 'countdown'), 'resets in 1 h 30 min');
  assert.match(Limits.resets(T0 + 90 * 60, T0, 'time'), /^resets (\w{3} )?\d\d:\d\d$/);
  assert.match(Limits.resets(T0 + 90 * 60, T0, 'both'), /^resets (\w{3} )?\d\d:\d\d · in 1 h 30 min$/);
  assert.match(Limits.resets(T0 + 3 * 24 * H, T0, 'time'), /^resets \w{3} \d\d:\d\d$/);
});

test('until: time left in words', () => {
  assert.equal(Limits.until(T0 + 90 * 60, T0), '1 h 30 min');
  assert.equal(Limits.until(T0 + 40 * 60, T0), '40 min');
  assert.equal(Limits.until(T0 + 50 * H, T0), '2 d 2 h');
  assert.equal(Limits.until(T0 + 30, T0), '1 min');
});

function row(hour, project, model, n = {}) {
  return { hour, project, model, input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0, ...n };
}

test('cost: each kind of token at its own price, per million', () => {
  const r = row(T0, '~/a', 'claude-opus-5-5', { input: 1e6, cache_write_5m: 1e6, cache_write_1h: 1e6, cache_read: 1e6, output: 1e6 });
  assert.equal(Limits.cost(r), 4 + 5 + 8 + 0.2 + 20);
});

test('cost: a dated model id takes the price of its model', () => {
  assert.equal(Limits.cost(row(T0, '~/a', 'claude-haiku-4-5-20251001', { output: 1e6 })), 5);
});

test('cost: fast mode doubles the price', () => {
  assert.equal(Limits.cost(row(T0, '~/a', 'claude-opus-5-5', { speed: 'fast', output: 1e6, cache_read: 1e6 })), 40.4);
});

test('cost: an unknown model has no price', () => {
  assert.equal(Limits.cost(row(T0, '~/a', 'claude-next-9', { output: 1e6 })), null);
});

test('projects: summed across models and accounts, dearest first', () => {
  const T = [
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6 }),
    row(T0, '~/b', 'claude-fable-5-1', { output: 1e6 }),
    row(T0 + H, '~/a', 'claude-sonnet-5', { output: 1e6 }),
  ];
  const { rows } = Limits.projects(T, T0, T0 + 2 * H);
  assert.deepEqual(rows.map(r => [r.name, r.tokens, r.cost]), [['~/b', 1e6, 50], ['~/a', 2e6, 30]]);
});

test('projects: an hour counts when it overlaps the range', () => {
  const T = [row(T0 - 2 * H, '~/old', 'claude-opus-5', { output: 1 }), row(T0 - H + 1, '~/edge', 'claude-opus-5', { output: 1 })];
  assert.deepEqual(Limits.projects(T, T0, T0 + H).rows.map(r => r.name), ['~/edge']);
});

test('projects: unknown models are named, their tokens still counted', () => {
  const { rows, unpriced } = Limits.projects([row(T0, '~/a', 'claude-next-9', { output: 5 })], T0, T0 + H);
  assert.deepEqual([rows[0].tokens, rows[0].cost, unpriced], [5, 0, ['claude-next-9']]);
});

test('projects: split by agent, the session itself as main session', () => {
  const T = [
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6 }),
    row(T0, '~/a', 'claude-haiku-4-5', { output: 1e6, agent: 'Explore' }),
    row(T0 + H, '~/b', 'claude-haiku-4-5', { output: 1e6, agent: 'Explore' }),
  ];
  const { rows } = Limits.projects(T, T0, T0 + 2 * H, 'agent');
  assert.deepEqual(rows.map(r => [r.name, r.tokens, r.cost]), [['main session', 1e6, 20], ['Explore', 2e6, 10]]);
});

test('projects: split by session, its title or else its folder', () => {
  const T = [
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6, session: 's1', title: 'Deploy plan' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 2e6, session: 's2' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 3e6, session: 's3' }),
  ];
  assert.deepEqual(Limits.projects(T, T0, T0 + H, 'session').rows.map(r => [r.name, r.tokens]), [['~/a', 5e6], ['Deploy plan', 1e6]]);
});

test('projects: split by source, the entrypoint of the run', () => {
  const T = [
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6, entry: 'cli' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 2e6, entry: 'sdk-cli' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6 }),
  ];
  assert.deepEqual(Limits.projects(T, T0, T0 + H, 'source').rows.map(r => [r.name, r.tokens]), [['sdk-cli', 2e6], ['cli', 1e6], ['?', 1e6]]);
});

test('projects: split by machine, the host tally ran on', () => {
  const T = [
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6, host: 'Snowden' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 2e6, host: 'server' }),
    row(T0, '~/a', 'claude-opus-5-5', { output: 1e6 }),
  ];
  assert.deepEqual(Limits.projects(T, T0, T0 + H, 'machine').rows.map(r => [r.name, r.tokens]), [['server', 2e6], ['Snowden', 1e6], ['?', 1e6]]);
});

test('tokens: short units', () => {
  assert.deepEqual([999, 1500, 2.5e6, 345.8e6, 1.44e9].map(Limits.tokens), ['999', '1.5 k', '2.5 M', '346 M', '1.4 B']);
});

test('dollars: two decimals, thousands separated', () => {
  assert.deepEqual([0, 3.456, 12345.6].map(Limits.dollars), ['$0.00', '$3.46', '$12,345.60']);
});

test('clip: the part of a stepped line inside the window, its edges at the value held there', () => {
  const line = [{ t: T0, pct: 10 }, { t: T0 + 2 * H, pct: 30 }, { t: T0 + 4 * H, pct: 50 }];
  assert.deepEqual(Limits.clip(line, T0 + H, T0 + 3 * H), [{ t: T0 + H, pct: 10 }, { t: T0 + 2 * H, pct: 30 }, { t: T0 + 3 * H, pct: 30 }]);
  assert.deepEqual(Limits.clip(line, T0 + 5 * H, T0 + 6 * H), []);
});

test('windows: one per reset, starting one window length before it', () => {
  const S = [
    snap(T0 + 100, 'hw', [10, T0 + 5 * H], null),
    snap(T0 + 200, 'hw', [20, T0 + 5 * H], null),
    snap(T0 + 6 * H, 'hw', [5, T0 + 11 * H], null),
  ];
  const w = Limits.windows(S, 'five_hour', T0, T0 + 7 * H);
  assert.deepEqual(w.map(w => [w.start, w.end]), [[T0, T0 + 5 * H], [T0 + 6 * H, T0 + 11 * H]]);
  assert.deepEqual(w[0].fill[0].map(p => p.pct), [10, 20, 20]);
  assert.deepEqual(w.map(w => w.peak), [20, 5]);
});

test('windows: a weekly window outside the range is left out', () => {
  const S = [snap(T0, 'hw', null, [40, T0 + DAY]), snap(T0 + 10 * DAY, 'hw', null, [5, T0 + 14 * DAY])];
  assert.deepEqual(Limits.windows(S, 'seven_day', T0 + 9 * DAY, T0 + 11 * DAY).map(w => w.end), [T0 + 14 * DAY]);
});




