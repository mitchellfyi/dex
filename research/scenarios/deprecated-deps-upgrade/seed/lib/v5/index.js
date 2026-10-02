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

function connect(config = {}) {
  if (!config.baseUrl || !config.apiToken) {
    throw new TypeError('baseUrl and apiToken are required');
  }

  return {
    async getUser({ id }) {
      const user = USERS[id];
      if (!user) {
        throw new Error(`user not found: ${id}`);
      }
      return { ...user };
    },

    async getOrders({ userId }) {
      return (ORDERS[userId] || []).map(order => ({ ...order }));
    },

    async createCharge({ paymentMethod, amountCents }) {
      if (!paymentMethod) {
        throw new Error('paymentMethod is required');
      }
      return {
        id: `ch_${paymentMethod}_${amountCents}`,
        amountCents,
        status: 'succeeded'
      };
    }
  };
}

const money = {
  format({ amountCents, currencyCode = 'USD' }) {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: currencyCode }).format(amountCents / 100);
  }
};

const dates = {
  parseIso(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(value)) {
      throw new TypeError('parseIso expects an ISO timestamp');
    }
    return new Date(value);
  }
};

const validators = {
  email(value) {
    return typeof value === 'string' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
  },

  required(record, fields) {
    return fields.filter(field => record[field] === undefined || record[field] === null || record[field] === '');
  }
};

function createLogger({ scope }) {
  return {
    warn({ message, context = {} }) {
      return { level: 'warn', scope, message, context };
    }
  };
}

module.exports = {
  connect,
  money,
  dates,
  validators,
  createLogger
};
