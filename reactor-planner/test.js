// node reactor-planner/test.js
const assert = require('assert');
const S = require('./sim.js');

// HashMap order: hashes 961, 992, 962 -> buckets 1, 0, 2 at cap 16
assert.deepStrictEqual(S.javaOrder([[0, 0], [1, 0], [0, 1]], 16), [[1, 0], [0, 0], [0, 1]]);

// pulses: quad = 12 internal + 4 per reflector; single next to quad gets +4
let m = S.compile(['R4R', '.1.']);
const p = (x, z) => m.pulses[m.order.findIndex(k => k[0] === x && k[1] === z)];
assert.strictEqual(p(1, 0), 12 + 4 + 4 + 1);
assert.strictEqual(p(1, 1), 1 + 4);

// heat formula uses integer division
assert.deepStrictEqual([1, 2, 3, 4, 5].map(S.heatPerTick), [4, 6, 7, 12, 14]);

// lone rod: +4/tick forever -> overheats; rod + vent: vent removes >= 4/tick -> stable
assert.strictEqual(S.evaluate(['1']).stable, false);
const e = S.evaluate(['1V'], { height: 3 });
assert.ok(e.stable && e.peak <= 4, 'rod+vent stable');
assert.strictEqual(e.rf, 64 * 3);

// absorber removes 16 from each warm neighbor and uses coolant only when it did
const a = S.evaluate(['1A1']);
assert.ok(a.stable && a.coolant > 0 && a.coolant <= 1);

// optimizer finds something stable and positive on a tiny grid
let last;
for (const s of S.optimize(['...', '...', '...'], { allowed: S.TYPES, iters: 1500 })) last = s;
const best = S.evaluate(last.best.map(r => r.join('')), { ticks: 40000 });
assert.ok(best.stable && best.rf > 0, 'optimizer result stable');
console.log('ok', last.best.map(r => r.join('')).join('/'), best.rf, 'RF/t');
