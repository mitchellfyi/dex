const USERS = {
  u1: { id: 'u1', name: 'Ada Lovelace', email: 'ada@example.com', createdAt: '2026-01-03T10:30:00.000Z' },
  u2: { id: 'u2', name: 'Grace Hopper', email: 'grace@example.com', createdAt: '2026-02-04T11:00:00.000Z' }
};

const ORDERS = {
  u1: [
    { id: 'o1', userId: 'u1', totalCents: 1200, createdAt: '2026-03-01T09:00:00.000Z' },
    { id: 'o2', userId: 'u1', totalCents: 2300, createdAt: '2026-03-02T09:00:00.000Z' }
  ],
  u2: [
    { id: 'o3', userId: 'u2', totalCents: 4500, createdAt: '2026-03-03T09:00:00.000Z' }
  ]
};

function createClient(config = {}) {
  if (!config.endpoint || !config.token) {
    throw new TypeError('endpoint and token are required');
  }

  return {
    fetchUser(id, callback) {
      setImmediate(() => {
        const user = USERS[id];
        if (!user) {
          callback(new Error(`user not found: ${id}`));
          return;
        }
        callback(null, { ...user });
      });
    },

    listOrders(userId, callback) {
      setImmediate(() => {
        callback(null, (ORDERS[userId] || []).map(order => ({ ...order })));
      });
    },

    chargeCard(cardToken, amountCents, callback) {
      setImmediate(() => {
        if (!cardToken) {
          callback(new Error('card token is required'));
          return;
        }
        callback(null, {
          id: `ch_${cardToken}_${amountCents}`,
          amountCents,
          status: 'succeeded'
        });
      });
    }
  };
}

function formatMoney(cents, currency = 'USD') {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(cents / 100);
}

function parseDate(value) {
  return new Date(value);
}

class Validator {
  checkEmail(value) {
    return typeof value === 'string' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
  }

  requireFields(record, fields) {
    return fields.filter(field => record[field] === undefined || record[field] === null || record[field] === '');
  }
}

const logger = {
  warn(message, meta = {}) {
    return { level: 'warn', message, meta };
  }
};

module.exports = {
  createClient,
  formatMoney,
  parseDate,
  Validator,
  logger
};
