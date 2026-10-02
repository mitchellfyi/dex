const { subscribe } = require('@orderly/shared').queue;
const { sendOrderEmail } = require('./jobs/email');

async function main() {
  console.log('worker starting');
  await subscribe('order.placed', async (msg) => {
    await sendOrderEmail(msg.orderId);
  });
}

main().catch((err) => {
  console.error('worker fatal', err);
  process.exit(1);
});
