const express = require('express');
const usersRouter = require('./routes/users');
const ordersRouter = require('./routes/orders');
const { connectDb } = require('./db');

const app = express();
app.use(express.json());
app.use('/users', usersRouter);
app.use('/orders', ordersRouter);

const PORT = process.env.PORT || 3000;
connectDb().then(() => {
  app.listen(PORT, () => console.log(`api listening on :${PORT}`));
});
