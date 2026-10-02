const router = require('express').Router();
const { getPool } = require('../db');

router.post('/', async (req, res) => {
  const { email, name } = req.body;
  const { rows } = await getPool().query(
    'INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id, email, name',
    [email, name]
  );
  res.status(201).json(rows[0]);
});

router.get('/:id', async (req, res) => {
  const { rows } = await getPool().query('SELECT id, email, name FROM users WHERE id = $1', [req.params.id]);
  if (!rows.length) return res.status(404).json({ error: 'not found' });
  res.json(rows[0]);
});

module.exports = router;
