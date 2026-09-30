'use strict';
// Regenerate golden.json from the seed:
//   node _generate-golden.js ../../seed
// Run it only when a case changes. The seed is the definition of correct.

const fs = require('node:fs');
const path = require('node:path');
const { CASES } = require('./_cases');

async function main() {
  const seed = path.resolve(process.argv[2] || path.join(__dirname, '..', '..', 'seed'));
  const lib = require(path.join(seed, 'src', 'notifications'));
  const golden = {};
  for (const [name, run] of Object.entries(CASES)) {
    // Cases share no state, but keep the output order stable.
    golden[name] = await run(lib);
  }
  fs.writeFileSync(path.join(__dirname, 'golden.json'), `${JSON.stringify(golden, null, 2)}\n`);
  console.log(`wrote ${Object.keys(golden).length} cases`);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
