'use strict';

class CatalogUnavailableError extends Error {
  constructor(cause) {
    super('catalog request failed', { cause });
    this.name = 'CatalogUnavailableError';
  }
}

async function requestCatalog(transport) {
  try {
    const response = await transport.get('/catalog');
    if (!response || !Array.isArray(response.items)) {
      throw new TypeError('catalog response must contain an items array');
    }
    return response;
  } catch (error) {
    throw new CatalogUnavailableError(error);
  }
}

module.exports = { CatalogUnavailableError, requestCatalog };
