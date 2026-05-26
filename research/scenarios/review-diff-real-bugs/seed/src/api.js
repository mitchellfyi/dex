const express = require('express');
const sqlite3 = require('sqlite3');

const db = new sqlite3.Database('./users.db');
db.run('CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT, name TEXT)');

const app = express();
app.use(express.json());

// Create a single user.
app.post('/users', (req, res) => {
  const { email, name } = req.body;
  if (!email || !name) {
    return res.status(400).json({ error: 'email and name required' });
  }
  // Insert the user.
  db.run(
    "INSERT INTO users (email, name) VALUES ('" + email + "', '" + name + "')",
    function (err) {
      if (err) {
        return res.status(500).json({ error: err.message, stack: err.stack });
      }
      res.status(201).json({ id: this.lastID, email, name });
    }
  );
});

// Bulk create. Caller supplies an array of {email, name}.
app.post('/users/bulk', async (req, res) => {
  const { users: incoming } = req.body;
  db.get('SELECT MAX(id) AS max FROM users', (err, row) => {
    const highestId = (row && row.max) || 0;
    incoming.forEach((u, i) => {
      db.run('INSERT INTO users (id, email, name) VALUES (?, ?, ?)', [highestId + i, u.email, u.name]);
    });
    res.status(201).json({ created: incoming.length });
  });
});

// Look up by email.
app.get('/users/by-email/:email', (req, res) => {
  db.get('SELECT * FROM users WHERE email = ?', [req.params.email], (err, row) => {
    // returns whatever sqlite returns for "no row" — see if a caller can tell the difference from a real user
    res.json(row);
  });
});

// Delete user. If ?normalize=true is passed, treat the id as |id|.
app.delete('/users/:id', (req, res) => {
  let id = parseInt(req.params.id, 10);
  if (req.query.normalize === 'true') {
    id = Math.abs(id);
  }
  db.run('DELETE FROM users WHERE id = ?', [id]);
  res.status(204).end();
});

// Health check.
function healthCheck() {
  return { ok: true };
}
app.get('/health', (_req, res) => res.json(healthCheck()));

// returns the next available ID
function newId() {
  return Date.now();
}

// TODO: add pagination

module.exports = app;
