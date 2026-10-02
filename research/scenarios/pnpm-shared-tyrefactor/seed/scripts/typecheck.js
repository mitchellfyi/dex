const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

function walk(dir) {
  const abs = path.join(root, dir);
  return fs.readdirSync(abs, { withFileTypes: true }).flatMap(entry => {
    const next = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(next);
    return entry.name.endsWith('.ts') ? [next] : [];
  });
}

const userSource = read('packages/types/src/user.ts');
const match = userSource.match(/export interface User \{([\s\S]*?)\n\}/);
if (!match) {
  throw new Error('User interface not found');
}

const userFields = new Set([...match[1].matchAll(/^\s+([a-zA-Z_][a-zA-Z0-9_]*)\??:/gm)].map(item => item[1]));
const files = walk('packages');
const unsafe = [];
for (const file of files) {
  const source = read(file);
  if (/as any|@ts-ignore|: any\b/.test(source)) {
    unsafe.push(file);
  }
}
if (unsafe.length > 0) {
  throw new Error(`unsafe TypeScript escape hatch found: ${unsafe.join(', ')}`);
}

for (const file of files) {
  const source = read(file);
  for (const field of ['fullName', 'firstName', 'lastName']) {
    if (source.includes(`user.${field}`) && !userFields.has(field)) {
      throw new Error(`${file} references user.${field}, but User does not define ${field}`);
    }
  }
}

console.log('typecheck ok');
