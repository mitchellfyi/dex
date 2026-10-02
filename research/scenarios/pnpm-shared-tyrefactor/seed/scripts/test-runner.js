const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

const userSource = read('packages/types/src/user.ts');
const usesFullName = /fullName:\s*string/.test(userSource);
const usesSplitName = /firstName:\s*string/.test(userSource) && /lastName:\s*string/.test(userSource);
const frontendFixture = read('packages/frontend/tests/user-card.test.ts');
const backendFixture = read('packages/backend/tests/user-route.test.ts');

if (!usesFullName && !usesSplitName) {
  throw new Error('User must use either fullName or firstName/lastName');
}

if (usesFullName) {
  if (!frontendFixture.includes('fullName') || !backendFixture.includes('fullName')) {
    throw new Error('fullName fixtures are missing');
  }
}

if (usesSplitName) {
  if (!frontendFixture.includes('firstName') || !frontendFixture.includes('lastName')) {
    throw new Error('frontend fixture was not migrated');
  }
  if (!backendFixture.includes('firstName') || !backendFixture.includes('lastName')) {
    throw new Error('backend fixture was not migrated');
  }
  if (!/displayName/.test(userSource)) {
    throw new Error('displayName helper is required after split-name migration');
  }
}

console.log('tests ok');
