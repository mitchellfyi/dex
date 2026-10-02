const Redis = require('ioredis');

const redis = new Redis(process.env.REDIS_URL);

async function enqueue(topic, payload) {
  await redis.lpush(`q:${topic}`, JSON.stringify(payload));
}

async function subscribe(topic, handler) {
  while (true) {
    const result = await redis.brpop(`q:${topic}`, 0);
    if (!result) continue;
    const msg = JSON.parse(result[1]);
    try {
      await handler(msg);
    } catch (err) {
      console.error('handler failed', err);
    }
  }
}

module.exports = { enqueue, subscribe };
