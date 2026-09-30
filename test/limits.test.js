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

test('current: no snapshots', () => {
  assert.equal(Limits.current([], T0), null);
});

test('current: a window that never came is null', () => {
  const S = [snap(T0, 'reconnact', [80, T0 + 5 * H], null)];
  assert.equal(Limits.current(S, T0 + 10).seven_day, null);
});

test('segments: the line drops to 0 where a window ends and runs to the right edge', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null),
    snap(T0 + 6 * H, 'reconnact', [3, T0 + 11 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 7 * H), [[
    { t: T0 + 100, pct: 80 },
    { t: T0 + 5 * H, pct: 0 },
    { t: T0 + 6 * H, pct: 3 },
    { t: T0 + 7 * H, pct: 3 },
  ]]);
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

test('segments: more than a day without a snapshot breaks the line', () => {
  const S = [
    snap(T0, 'hw', [50, T0 + 5 * H], null),
    snap(T0 + 3 * DAY, 'hw', [10, T0 + 3 * DAY + 5 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0 - H, T0 + 3 * DAY + H), [
    [{ t: T0, pct: 50 }, { t: T0, pct: 50 }],
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

test('segments: a snapshot without the window counts as 0', () => {
  const S = [
    snap(T0, 'hw', [80, T0 + H], [40, T0 + 100 * H]),
    snap(T0 + 2 * H, 'hw', null, [40, T0 + 100 * H]),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 2 * H), [[
    { t: T0, pct: 80 },
    { t: T0 + H, pct: 0 },
    { t: T0 + 2 * H, pct: 0 },
  ]]);
});

test('segments: a last snapshot older than a day ends the line there', () => {
  const S = [
    snap(T0, 'hw', [50, T0 + 5 * H], null),
    snap(T0 + H, 'hw', [60, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.segments(S, 'five_hour', T0, T0 + 3 * DAY), [[
    { t: T0, pct: 50 },
    { t: T0 + H, pct: 60 },
    { t: T0 + H, pct: 60 },
  ]]);
});

test('segments: a line that ended before the range is left out', () => {
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

test('path: no points, no path', () => {
  assert.equal(Limits.path([], 0, 100, 200, 100), '');
});

test('until: time left in words', () => {
  assert.equal(Limits.until(T0 + 90 * 60, T0), '1 h 30 min');
  assert.equal(Limits.until(T0 + 40 * 60, T0), '40 min');
  assert.equal(Limits.until(T0 + 50 * H, T0), '2 d 2 h');
  assert.equal(Limits.until(T0 + 30, T0), '1 min');
});
