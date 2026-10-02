const { createClient, parseDate } = require('../lib/v3');
const { clientConfig } = require('./client-config');

function callbackToPromise(register) {
  return new Promise((resolve, reject) => {
    register((err, value) => {
      if (err) {
        reject(err);
        return;
      }
      resolve(value);
    });
  });
}

async function loadCustomerSummary(userId) {
  const client = createClient(clientConfig());
  const user = await callbackToPromise(done => client.fetchUser(userId, done));
  const orders = await callbackToPromise(done => client.listOrders(userId, done));

  return {
    id: user.id,
    name: user.name,
    email: user.email,
    createdYear: parseDate(user.createdAt).getUTCFullYear(),
    orderCount: orders.length,
    totalCents: orders.reduce((sum, order) => sum + order.totalCents, 0)
  };
}

module.exports = { loadCustomerSummary };
