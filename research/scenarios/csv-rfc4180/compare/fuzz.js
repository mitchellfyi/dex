'use strict';
// Differential fuzzing for csv-rfc4180. The spec fixes every output, so the
// reference is exact: for random rows, stringify must produce the reference's
// text and parse must read it back; for random text, valid or not, parse must
// return what the reference returns or throw the same error at the same
// line and column, and so must createParser fed the text in random pieces.

const path = require('node:path');

const CHARS = ['a', 'b', 'Z', '1', ' ', '\t', ',', ';', '|', '"', '\r', '\n', 'ü', '日', '😀', '#'];
const DELIMITERS = [',', ';', '\t', '|'];

function lib(ws) {
  return require(path.join(ws, 'src', 'csv.js'));
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function word(rng, max) {
  let out = '';
  const n = Math.floor(rng() * max);
  for (let i = 0; i < n; i++) {
    out += pick(rng, CHARS);
  }
  return out;
}

function options(rng) {
  const opts = {};
  if (rng() < 0.5) opts.delimiter = pick(rng, DELIMITERS);
  if (rng() < 0.3) opts.eol = '\n';
  if (rng() < 0.3) opts.skipEmptyLines = true;
  return opts;
}

function observe(fn) {
  try {
    return { value: fn() };
  } catch (err) {
    return { error: err && err.name, line: err && err.line, column: err && err.column };
  }
}

async function runSequence({ agentWs, refWs, rng, steps }) {
  const agent = lib(agentWs);
  const ref = lib(refWs);
  for (let step = 0; step < steps; step++) {
    const opts = options(rng);
    if (rng() < 0.5) {
      const rows = Array.from({ length: 1 + Math.floor(rng() * 4) }, () =>
        Array.from({ length: 1 + Math.floor(rng() * 4) }, () => word(rng, 6))
      );
      const want = observe(() => ref.stringify(rows, opts));
      const got = observe(() => agent.stringify(rows, opts));
      if (JSON.stringify(want) !== JSON.stringify(got)) {
        return { step, op: `stringify(${JSON.stringify(rows)}, ${JSON.stringify(opts)})`, expected: want, actual: got };
      }
      const back = observe(() => agent.parse(want.value, opts));
      if (JSON.stringify(back) !== JSON.stringify({ value: rows })) {
        return { step, op: `parse(${JSON.stringify(want.value)}, ${JSON.stringify(opts)})`, expected: { value: rows }, actual: back, note: 'round trip' };
      }
    } else {
      let text = word(rng, 30);
      if (rng() < 0.1) text = `﻿${text}`;
      if (rng() < 0.25) opts.header = true;
      const want = observe(() => ref.parse(text, opts));
      const got = observe(() => agent.parse(text, opts));
      if (JSON.stringify(want) !== JSON.stringify(got)) {
        return { step, op: `parse(${JSON.stringify(text)}, ${JSON.stringify(opts)})`, expected: want, actual: got };
      }
      // The same text in random pieces must give the same records or error.
      const chunks = [];
      // Sizes 0-4: empty writes are part of what is being tested.
      for (let i = 0; i < text.length; ) {
        const size = Math.floor(rng() * 5);
        chunks.push(text.slice(i, i + size));
        i += size;
      }
      const streamed = observe(() => {
        const parser = agent.createParser(opts);
        const out = [];
        for (const chunk of chunks) {
          out.push(...parser.write(chunk));
        }
        out.push(...parser.end());
        return out;
      });
      if (JSON.stringify(want) !== JSON.stringify(streamed)) {
        return { step, op: `createParser(${JSON.stringify(opts)}) fed ${JSON.stringify(chunks)}`, expected: want, actual: streamed, note: 'chunked parse' };
      }
    }
  }
  return null;
}

module.exports = { runSequence };
