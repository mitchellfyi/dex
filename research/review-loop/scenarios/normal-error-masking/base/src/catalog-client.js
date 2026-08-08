'use strict';

async function requestCatalog(transport) {
  return transport.get('/catalog');
}

module.exports = { requestCatalog };
