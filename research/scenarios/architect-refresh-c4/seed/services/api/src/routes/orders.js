const router = require('express').Router();
const { getPool } = require('../db');
const { enqueue } = require('@orderly/shared').queue;

router.post('/', async (req, res) => {
  const { userId, items, total } = req.body;
  const { rows } = await getPool().query(
    'INSERT INTO orders (user_id, items, total, status) VALUES ($1, $2, $3, $4) RETURNING *',
    [userId, JSON.stringify(items), total, 'pending']
  );
  await enqueue('order.placed', { orderId: rows[0].id });
  res.status(201).json(rows[0]);
});

router.get('/:id', async (req, res) => {
  const { rows } = await getPool().query('SELECT * FROM orders WHERE id = $1', [req.params.id]);
  if (!rows.length) return res.status(404).json({ error: 'not found' });
  res.json(rows[0]);
});

module.exports = router;
