// Oritech fission reactor model. Mirrors ReactorControllerBlockEntity.serverTick, whose math is
// unchanged from Oritech 0.19 through 1.2.x (MC 1.21.1, what ATM10 ships).
// Grid = array of strings, row = z, column = x. Glyphs: . empty, 1/2/4 rods, R reflector, P pipe, V vent, A absorber.
// Every column is the same block for the full height, so the sim is one 2D layer; RF/fuel/coolant scale with height, heat does not.
(function (root) {
  const CFG = { rfPerPulse: 64, absorberRate: 16, ventBaseRate: 4, ventRelativeRate: 100, maxHeat: 2000 };
  const RODS = { '1': [1, 1], '2': [2, 4], '4': [4, 12] }; // glyph -> [rodCount, internalPulses]
  const TYPES = ['.', '1', '2', '4', 'R', 'P', 'V', 'A'];

  // Java HashMap iteration: bucket index asc, then insertion order. JOML Vector2i.hashCode = 31*(31+x)+y,
  // small enough that HashMap's h ^ (h >>> 16) spread is a no-op.
  // ponytail: ignores treeified bins (8+ keys sharing a bucket), not reachable at sane reactor sizes.
  function javaOrder(keys, initialCap) {
    let cap = initialCap;
    while (keys.length > cap * 0.75) cap *= 2;
    return keys.map((k, i) => ({ k, i, b: (961 + 31 * k[0] + k[1]) & (cap - 1) }))
      .sort((a, b) => a.b - b.b || a.i - b.i).map(e => e.k);
  }

  function compile(grid) {
    const keys = [];
    for (let z = 0; z < grid.length; z++)        // BlockPos.betweenClosed: x fastest, then z
      for (let x = 0; x < grid[z].length; x++)
        if (grid[z][x] !== '.') keys.push([x, z]);
    const order = javaOrder(keys, 16);           // activeComponents = new HashMap<>()
    const idx = new Map(order.map((k, i) => [k + '', i]));
    const at = (x, z) => idx.get(x + ',' + z);
    const n = order.length, type = [], nb = [], pulses = new Int32Array(n), rodCount = new Int32Array(n);
    order.forEach(([x, z], i) => {
      const t = grid[z][x];
      type.push(t);
      const cand = [[x - 1, z], [x, z + 1], [x + 1, z], [x, z - 1]].filter(([a, b]) => at(a, b) !== undefined);
      nb.push(javaOrder(cand, 4).map(([a, b]) => at(a, b))); // new HashSet<>(4)
      if (RODS[t]) {
        rodCount[i] = RODS[t][0];
        pulses[i] = RODS[t][1];
        for (const [a, b] of cand) {
          const o = grid[b][a];
          if (RODS[o]) pulses[i] += RODS[o][0];
          else if (o === 'R') pulses[i] += RODS[t][0];
        }
      }
    });
    return { n, order, type, nb, pulses, rodCount };
  }

  const heatPerTick = p => Math.trunc(p / 2) * p + 4;

  // Assumes every rod is fueled and every absorber has coolant. Aborts once any cell exceeds `limit`.
  function run(m, ticks, cfg, limit, heat) {
    heat = heat || new Int32Array(m.n);
    const { type, nb, pulses } = m;
    const q3 = Math.floor(ticks / 2), q4 = Math.floor(ticks * 3 / 4);
    let p3 = -Infinity, p4 = -Infinity, coolantUses = 0;
    for (let t = 0; t < ticks; t++) {
      let hottest = 0;
      for (let i = 0; i < m.n; i++) {
        let h = heat[i];
        const ty = type[i], ns = nb[i];
        if (ty === 'P') {
          for (const j of ns) {
            const d = heat[j] - h;
            if (d <= 0) continue;
            const g = Math.min(Math.trunc(d / 4) + 10, d);
            heat[j] -= g; h += g;
          }
        } else if (ty === 'A') {
          let used = false;
          for (const j of ns) if (heat[j] > 0) { heat[j] -= cfg.absorberRate; used = true; }
          if (used && t >= q4) coolantUses++;
        } else if (ty === 'V') {
          let hot = -1, max = 0;
          for (const j of ns) if (heat[j] > max) { hot = j; max = heat[j]; }
          if (hot >= 0) heat[hot] = max - Math.min(Math.trunc(max / cfg.ventRelativeRate) + cfg.ventBaseRate, max);
        } else if (pulses[i]) {
          h += heatPerTick(pulses[i]);
        }
        heat[i] = h;
        if (h > hottest) hottest = h;
      }
      if (hottest > limit) return { heat, overheated: true, tick: t, peak: hottest, prevPeak: p3, coolantPerTick: 0 };
      if (t >= q4) p4 = Math.max(p4, hottest); else if (t >= q3) p3 = Math.max(p3, hottest);
    }
    return { heat, overheated: false, tick: ticks, peak: p4, prevPeak: p3, coolantPerTick: coolantUses / (ticks - q4) };
  }

  // Per-layer numbers times height. Stable = never passed `limit` and the peak stopped climbing.
  function evaluate(grid, opts = {}) {
    const cfg = { ...CFG, ...opts.cfg }, H = opts.height || 1;
    const limit = opts.limit ?? cfg.maxHeat;
    const m = compile(grid);
    const r = run(m, opts.ticks || 3000, cfg, limit);
    let pulseSum = 0, fuel = 0;
    for (let i = 0; i < m.n; i++) { pulseSum += m.pulses[i]; fuel += m.rodCount[i]; }
    const stable = !r.overheated && r.peak - r.prevPeak <= limit * 0.01;
    return {
      m, ...r, stable, limit,
      rf: cfg.rfPerPulse * pulseSum * H,      // RF/t
      fuel: fuel * H,                          // fuel units/t
      coolant: r.coolantPerTick * H,           // coolant units/t (1 ice = 1000)
      eff: fuel ? cfg.rfPerPulse * pulseSum / fuel : 0, // RF per fuel unit
      parts: m.n,
    };
  }

  // Simulated annealing over the layer. Generator yields progress so the page stays responsive.
  // ponytail: single chain + revert-to-best, good enough to ~15x15; parallel chains/workers if bigger is needed.
  function* optimize(start, opts) {
    const { allowed, objective = 'rf', iters = 20000 } = opts;
    const W = start[0].length, D = start.length;
    const score = e => !e.stable ? -Infinity
      : objective === 'eff' ? e.eff + e.rf * 1e-4 - e.parts * 1e-3
      : e.rf + e.eff * 1e-2 - e.parts * 1e-2;
    const verify = g => evaluate(g, { ...opts, height: 1, ticks: 40000 });
    let cur = start.map(r => [...r]), curS = score(evaluate(cur, { ...opts, height: 1 }));
    if (curS === -Infinity) { cur = start.map(r => [...r].fill('.')); curS = score(evaluate(cur, { ...opts, height: 1 })); }
    let best = cur, bestS = curS, lastImprove = 0;
    for (let i = 0; i < iters; i++) {
      const cand = cur.map(r => [...r]);
      do {
        cand[Math.random() * D | 0][Math.random() * W | 0] = allowed[Math.random() * allowed.length | 0];
      } while (Math.random() < 0.3);
      const s = score(evaluate(cand, { ...opts, height: 1 }));
      const temp = 0.05 * Math.max(bestS, 256) * (1 - i / iters) ** 2 + 1e-9;
      if (s >= curS || Math.random() < Math.exp((s - curS) / temp)) { cur = cand; curS = s; }
      if (s > bestS && score(verify(cand)) > -Infinity) { best = cand; bestS = s; lastImprove = i; }
      if (i - lastImprove > 3000) { cur = best; curS = bestS; lastImprove = i; }
      if (i % 100 === 0) yield { i, best, bestS };
    }
    yield { i: iters, best, bestS };
  }

  const api = { CFG, RODS, TYPES, javaOrder, compile, heatPerTick, run, evaluate, optimize };
  if (typeof module !== 'undefined') module.exports = api; else root.ReactorSim = api;
})(this);
