'use strict';
// perf-child.js <perf.js> <workload name> <workspace>
//
// Runs one workload once against one implementation and prints
// {"ms": N, "maxRssKb": N}, or {"error": "..."}. perf-runner.js starts a
// fresh process for every measurement so the module cache, JIT state and
// heap of one implementation never carry over to the other.

const path = require('node:path');

async function main() {
  const [perfFile, name, ws] = process.argv.slice(2);
  const { workloads } = require(path.resolve(perfFile));
  const workload = workloads.find(w => w.name === name);
  if (!workload) {
    throw new Error(`no workload named ${name}`);
  }
  // Setup (loading the module, building fixtures) is not timed.
  const ctx = await workload.setup(path.resolve(ws));
  const start = process.hrtime.bigint();
  await workload.run(ctx);
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  process.stdout.write(`${JSON.stringify({ ms, maxRssKb: process.resourceUsage().maxRSS })}\n`);
}

main().catch(err => {
  process.stdout.write(`${JSON.stringify({ error: String((err && err.stack) || err).slice(0, 600) })}\n`);
  process.exitCode = 1;
});
