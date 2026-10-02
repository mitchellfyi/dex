'use strict';

function renderAccountCard(source, id) {
  const account = source.findAccount(id);
  return account ? `Account: ${account.displayName}` : 'Account unavailable';
}

module.exports = { renderAccountCard };
