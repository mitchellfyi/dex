'use strict';
// perf-runner.js <perf.js> <agent workspace> <reference workspace> <reps>
//
// Times every workload in a scenario's compare/perf.js against the agent's
// code and the reference solution, alternating which goes first, and prints
// the medians and their ratio as JSON. A ratio compares two implementations
// on the same machine in the same minute, so it survives a slower or busier
// host far better than an absolute time does.

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CHILD = path.join(__dirname, 'perf-child.js');

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Coefficient of variation: how much repeat runs of the same code disagree.
// Ratios from workloads with a high CV are noise, not findings.
function cv(values) {
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  const variance = values.reduce((sum, v) => sum + (v - mean) ** 2, 0) / Math.max(1, values.length - 1);
  return mean > 0 ? Math.sqrt(variance) / mean : null;
}

function measure(perfFile, name, ws) {
  const result = spawnSync(process.execPath, [CHILD, perfFile, name, ws], {
    encoding: 'utf8',
    timeout: 120000,
    env: { ...process.env, NO_COLOR: '1' }
  });
  if (result.error) {
    return { error: String(result.error) };
  }
  const line = (result.stdout || '').trim().split('\n').pop() || '';
  try {
    return JSON.parse(line);
  } catch (_err) {
    return { error: `no measurement (exit ${result.status}): ${(result.stderr || '').slice(-300)}` };
  }
}

function main() {
  const [perfFile, agentWs, refWs, repsRaw] = process.argv.slice(2);
  // An even count gives each implementation the first slot equally often.
  let reps = Number(repsRaw) || 6;
  reps += reps % 2;
  const { workloads } = require(path.resolve(perfFile));
  const out = { reps, workloads: [] };
  const ratios = [];
  for (const workload of workloads) {
    const samples = { agent: [], reference: [] };
    const rss = { agent: [], reference: [] };
    let error = null;
    // One untimed pair first: the first process to load a workspace pays for
    // cold file caches, and that is not a property of the code.
    for (const ws of [agentWs, refWs]) {
      const warm = measure(perfFile, workload.name, ws);
      if (warm.error && !error) {
        error = `${ws === agentWs ? 'agent' : 'reference'}: ${warm.error}`;
      }
    }
    for (let rep = 0; rep < reps && !error; rep++) {
      const order = rep % 2 ? ['reference', 'agent'] : ['agent', 'reference'];
      for (const who of order) {
        const m = measure(perfFile, workload.name, who === 'agent' ? agentWs : refWs);
        if (m.error) {
          error = `${who}: ${m.error}`;
          break;
        }
        samples[who].push(m.ms);
        rss[who].push(m.maxRssKb);
      }
    }
    const row = { name: workload.name, kind: workload.kind || 'module' };
    if (error) {
      row.error = error;
    } else {
      row.agent_ms = median(samples.agent);
      row.reference_ms = median(samples.reference);
      row.ratio = row.reference_ms > 0 ? row.agent_ms / row.reference_ms : null;
      row.cv = Math.max(cv(samples.agent), cv(samples.reference));
      row.agent_ms_samples = samples.agent;
      row.reference_ms_samples = samples.reference;
      if (row.kind === 'module') {
        row.agent_rss_kb = median(rss.agent);
        row.reference_rss_kb = median(rss.reference);
        row.rss_ratio = row.agent_rss_kb / row.reference_rss_kb;
      }
      if (row.ratio) {
        ratios.push(row.ratio);
      }
    }
    out.workloads.push(row);
  }
  out.errors = out.workloads.filter(w => w.error).length;
  out.load_average = require('node:os').loadavg();
  out.cpus = require('node:os').cpus().length;
  out.geomean_ratio = ratios.length
    ? Math.exp(ratios.reduce((sum, r) => sum + Math.log(r), 0) / ratios.length)
    : null;
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
}

main();
