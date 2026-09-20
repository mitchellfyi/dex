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

function liveScreen() {
  let active = true;
  const close = () => {
    if (!active) return;
    active = false;
    process.off('SIGINT', interrupt);
    process.off('SIGTERM', terminate);
    process.off('exit', close);
    process.stdout.write('\x1b[?25h\x1b[?1049l');
  };
  const interrupt = () => { close(); process.exit(130); };
  const terminate = () => { close(); process.exit(143); };
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', terminate);
  process.once('exit', close);
  process.stdout.write('\x1b[?1049h\x1b[?25l');
  return {
    render(frame, footerLines = 2) {
      let lines = frame.trimEnd().split('\n');
      const height = Math.max(3, (process.stdout.rows || 24) - 1);
      if (lines.length > height) {
        const footer = lines.slice(-Math.min(footerLines, height - 2));
        lines = [...lines.slice(0, height - footer.length - 1), '... use dx accounts to see all rows.', ...footer];
      }
      // Clear to the end of each line as well as the end of the screen: a
      // redraw that is narrower than the last one would otherwise leave the
      // tail of the old row sitting past the new one.
      process.stdout.write(`\x1b[H${lines.map(line => `${line}\x1b[K`).join('\n')}\x1b[J`);
    },
    close
  };
}

module.exports = { table, liveScreen };
