'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createAccountSource } = require('../src/account-source');
const { renderAccountCard } = require('../src/account-card');

test('renders an account returned by the source', () => {
  const source = createAccountSource([{ id: 'acct-1', name: 'Ada' }]);
  assert.equal(renderAccountCard(source, 'acct-1'), 'Account: Ada');
});
