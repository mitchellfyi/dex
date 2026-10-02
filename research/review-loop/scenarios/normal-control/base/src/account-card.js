'use strict';

function renderAccountCard(source, id) {
  const account = source.findAccount(id);
  return account ? `Account: ${account.name}` : 'Account unavailable';
}

module.exports = { renderAccountCard };
