'use strict';
// Performance workloads for inventory-race, timed against the reference,
// which serializes every call behind one lock. A finer-grained correct fix
// may come in under 1.00x here.

const path = require('node:path');

function service(ws) {
  const { InventoryService } = require(path.join(ws, 'src', 'index.js'));
  return new InventoryService();
}

module.exports.workloads = [
  {
    name: '2k sequential reserve+commit',
    setup: async ws => {
      const svc = service(ws);
      await svc.addStock('w', 100000);
      return { svc };
    },
    run: async ({ svc }) => {
      for (let i = 0; i < 2000; i++) {
        // Sequential on purpose: this measures per-call latency.
        await svc.reserve(`o${i}`, [{ sku: 'w', qty: 1 }]);
        await svc.commit(`o${i}`);
      }
    }
  },
  {
    name: '2k concurrent reserves over 50 SKUs',
    setup: async ws => {
      const svc = service(ws);
      for (let i = 0; i < 50; i++) {
        await svc.addStock(`s${i}`, 1000);
      }
      return { svc };
    },
    run: async ({ svc }) => {
      await Promise.all(Array.from({ length: 2000 }, (_, i) => svc.reserve(`c${i}`, [{ sku: `s${i % 50}`, qty: 1 }])));
    }
  }
];
