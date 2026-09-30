'use strict';
// Performance workloads for buggy-code-fix, timed against the reference cart
// by research/compare/js/perf-runner.js. Sizes are chosen so each run takes
// tens of milliseconds on the reference: long enough to measure, short enough
// to repeat.

const path = require('node:path');

function Cart(ws) {
  const mod = require(path.join(ws, 'src', 'cart.js'));
  return typeof mod === 'function' ? mod : mod.ShoppingCart || mod.default;
}

module.exports.workloads = [
  {
    name: 'add 5k distinct items',
    setup: ws => ({ Cart: Cart(ws) }),
    run: ({ Cart: C }) => {
      const cart = new C();
      for (let i = 0; i < 5000; i++) {
        cart.addItem(`item${i}`, 1 + (i % 7), 1 + (i % 3));
      }
      cart.getTotal();
    }
  },
  {
    name: 'total of 1k items, 10k times',
    setup: ws => {
      const cart = new (Cart(ws))();
      for (let i = 0; i < 1000; i++) {
        cart.addItem(`item${i}`, 2 + (i % 5), 1);
      }
      cart.applyDiscount(10);
      return { cart };
    },
    run: ({ cart }) => {
      for (let i = 0; i < 10000; i++) {
        cart.getTotal();
      }
    }
  },
  {
    name: 'add then remove 3k items',
    setup: ws => ({ Cart: Cart(ws) }),
    run: ({ Cart: C }) => {
      const cart = new C();
      for (let i = 0; i < 3000; i++) {
        cart.addItem(`item${i}`, 1, 1);
      }
      for (let i = 0; i < 3000; i++) {
        cart.removeItem(`item${i}`);
      }
    }
  }
];
