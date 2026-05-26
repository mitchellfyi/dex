const { Pool } = require('pg');

let pool;

async function connectDb() {
  pool = new Pool({ connectionString: process.env.DATABASE_URL });
  await pool.query('SELECT 1');
  return pool;
}

function getPool() {
  if (!pool) throw new Error('db not initialized');
  return pool;
}

module.exports = { connectDb, getPool };
