'use strict';
// fuzz-runner.js <fuzz.js> <agent workspace> <reference workspace> <sequences> <steps> <seed>
//
// Differential fuzzing. A scenario's compare/fuzz.js exports
// runSequence({ agentWs, refWs, rng, steps }), which drives both
// implementations with the same random operations and returns null when they
// agree or a description of the first step where they did not. Each sequence
// gets its own seed, so a divergence can be replayed exactly.

const path = require('node:path');

// mulberry32: small, fast and deterministic, which is all a fuzzer needs.
function rngFor(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

async function main() {
  const [fuzzFile, agentWs, refWs, seqRaw, stepsRaw, seedRaw] = process.argv.slice(2);
  const sequences = Number(seqRaw) || 20;
  const steps = Number(stepsRaw) || 30;
  const seed = Number(seedRaw) || 1;
  const fuzz = require(path.resolve(fuzzFile));
  const out = { sequences, steps, seed, passed: 0, divergences: [], harness_errors: [] };
  for (let i = 0; i < sequences; i++) {
    const sequenceSeed = seed * 1000 + i;
    try {
      // Sequential on purpose: CLI sequences share nothing, but module ones
      // share the agent's loaded module, and interleaving them hides which
      // sequence a divergence belongs to.
      const divergence = await fuzz.runSequence({
        agentWs: path.resolve(agentWs),
        refWs: path.resolve(refWs),
        rng: rngFor(sequenceSeed),
        steps
      });
      if (divergence) {
        out.divergences.push({ sequence_seed: sequenceSeed, ...divergence });
      } else {
        out.passed += 1;
      }
    } catch (err) {
      // An error the harness did not catch means the fuzz definition and
      // the reference disagree; that is a bug here, not in the agent's code.
      if (err && err.harness) {
        out.harness_errors.push({ sequence_seed: sequenceSeed, error: String(err.message) });
      } else {
        out.divergences.push({ sequence_seed: sequenceSeed, crash: String((err && err.stack) || err).slice(0, 600) });
      }
    }
  }
  out.pass_rate = out.passed / sequences;
  out.divergences = out.divergences.slice(0, 5);
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
}

main();
