'use strict';

const { requestCatalog } = require('./catalog-client');

async function listCatalog(transport) {
  try {
    const response = await requestCatalog(transport);
    return response.items;
  } catch (_error) {
    return [];
  }
}

module.exports = { listCatalog };
