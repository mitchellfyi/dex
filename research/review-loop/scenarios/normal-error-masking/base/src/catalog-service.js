'use strict';

const { requestCatalog } = require('./catalog-client');

async function listCatalog(transport) {
  const response = await requestCatalog(transport);
  return response.items;
}

module.exports = { listCatalog };
