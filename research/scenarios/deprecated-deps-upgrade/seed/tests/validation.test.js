const test = require('node:test');
const assert = require('node:assert/strict');
const { validateSignup } = require('../src/validation');

test('validates signups', () => {
  assert.deepEqual(validateSignup({ name: 'Ada', email: 'ada@example.com' }), {
    valid: true,
    errors: []
  });

  const invalid = validateSignup({ name: '', email: 'bad' });
  assert.equal(invalid.valid, false);
  assert.match(invalid.errors.join(' '), /name is required/);
  assert.match(invalid.errors.join(' '), /email is invalid/);
});
