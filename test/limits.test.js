const test = require('node:test');
const assert = require('node:assert/strict');
const Limits = require('../limits.js');

const H = 3600;
const T0 = 1790000000;

function snap(ts, source, h5, d7) {
  return {
    ts, source,
    five_hour: h5 && { used_percentage: h5[0], resets_at: h5[1] },
    seven_day: d7 && { used_percentage: d7[0], resets_at: d7[1] },
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

test('steps: the line drops to 0 where a window ends', () => {
  const S = [
    snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null),
    snap(T0 + 6 * H, 'reconnact', [3, T0 + 11 * H], null),
  ];
  const steps = Limits.steps(S, 'five_hour', T0, T0 + 7 * H);
  assert.deepEqual(steps, [
    { t: T0 + 100, pct: 80 },
    { t: T0 + 5 * H, pct: 0 },
    { t: T0 + 6 * H, pct: 3 },
  ]);
});

test('steps: a reset still ahead adds no drop', () => {
  const S = [snap(T0 + 100, 'reconnact', [80, T0 + 5 * H], null)];
  assert.deepEqual(Limits.steps(S, 'five_hour', T0, T0 + H), [{ t: T0 + 100, pct: 80 }]);
});

test('steps: the value before the range carries into it', () => {
  const S = [
    snap(T0 - 500, 'reconnact', [30, T0 + 5 * H], null),
    snap(T0 + 100, 'reconnact', [35, T0 + 5 * H], null),
  ];
  assert.deepEqual(Limits.steps(S, 'five_hour', T0, T0 + H), [
    { t: T0, pct: 30 },
    { t: T0 + 100, pct: 35 },
  ]);
});

test('steps: nothing in range, nothing before', () => {
  assert.deepEqual(Limits.steps([], 'five_hour', T0, T0 + H), []);
});

test('path: a step line scaled to the box, held until the right edge', () => {
  const steps = [{ t: 0, pct: 50 }, { t: 50, pct: 100 }];
  assert.equal(Limits.path(steps, 0, 100, 200, 100), 'M0 50H100V0H200');
});

test('path: no steps, no path', () => {
  assert.equal(Limits.path([], 0, 100, 200, 100), '');
});

test('until: time left in words', () => {
  assert.equal(Limits.until(T0 + 90 * 60, T0), '1 h 30 min');
  assert.equal(Limits.until(T0 + 40 * 60, T0), '40 min');
  assert.equal(Limits.until(T0 + 50 * H, T0), '2 d 2 h');
  assert.equal(Limits.until(T0 + 30, T0), '1 min');
});
