const nodemailer = require('nodemailer');
const { Pool } = require('pg');

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const transport = nodemailer.createTransport(process.env.SMTP_URL);

async function sendOrderEmail(orderId) {
  const { rows } = await pool.query(
    'SELECT o.id, o.total, u.email, u.name FROM orders o JOIN users u ON u.id = o.user_id WHERE o.id = $1',
    [orderId]
  );
  if (!rows.length) return;
  const order = rows[0];
  await transport.sendMail({
    from: 'noreply@orderly.example',
    to: order.email,
    subject: `Order #${order.id} received`,
    text: `Hi ${order.name}, we received your order. Total: ${order.total}.`,
  });
}

module.exports = { sendOrderEmail };
