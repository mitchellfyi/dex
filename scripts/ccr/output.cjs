'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

function table(headers, rows, { width = process.stdout.isTTY ? process.stdout.columns || 80 : null, rightAlign = [] } = {}) {
  if (!rows.length) return '';
  const result = spawnSync('python3', [path.join(__dirname, '..', 'terminal-table.py')], {
    input: JSON.stringify({ headers, rows, width, right_align: rightAlign }), encoding: 'utf8', maxBuffer: 16 * 1024 * 1024
  });
  if (result.error || result.status !== 0) throw new Error('Could not format the table. Check that Python 3 is available.');
  return result.stdout;
}

module.exports = { table };
