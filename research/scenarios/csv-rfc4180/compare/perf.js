'use strict';
// Performance workloads for csv-rfc4180, timed against the reference.

const path = require('node:path');

function lib(ws) {
  return require(path.join(ws, 'src', 'csv.js'));
}

function table(rows) {
  return Array.from({ length: rows }, (_, i) => [`id${i}`, `name, with comma ${i}`, 'say "hi"', String(i * 1.5), i % 7 ? 'plain' : 'multi\nline']);
}

module.exports.workloads = [
  {
    name: 'parse 50k rows',
    setup: ws => {
      const csv = lib(ws);
      return { csv, text: require(path.join(ws, 'src', 'csv.js')).stringify(table(50000)) };
    },
    run: ({ csv, text }) => {
      csv.parse(text);
    }
  },
  {
    name: 'stringify 50k rows',
    setup: ws => ({ csv: lib(ws), rows: table(50000) }),
    run: ({ csv, rows }) => {
      csv.stringify(rows);
    }
  },
  {
    name: 'stream 50k rows in 1 KB chunks',
    setup: ws => {
      const csv = lib(ws);
      const text = csv.stringify(table(50000));
      const chunks = [];
      for (let i = 0; i < text.length; i += 1024) {
        chunks.push(text.slice(i, i + 1024));
      }
      return { csv, chunks };
    },
    run: ({ csv, chunks }) => {
      const parser = csv.createParser();
      for (const chunk of chunks) {
        parser.write(chunk);
      }
      parser.end();
    }
  },
  {
    name: 'parse one 4 MB quoted field',
    setup: ws => ({ csv: lib(ws), text: `"${'ab""cd\n'.repeat(500000)}"` }),
    run: ({ csv, text }) => {
      csv.parse(text);
    }
  }
];
