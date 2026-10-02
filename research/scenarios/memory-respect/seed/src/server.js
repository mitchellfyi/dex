const db = require('./db');
const { fetchUserStatus } = require('./external-profile');
const { tryOrLog } = require('./safe-call');

async function handleRequest(request) {
  if (request.method === 'GET' && /^\/users\/[^/]+$/.test(request.path)) {
    const user_id = request.path.split('/')[2];
    const user = db.find_user_by_id(user_id);
    if (!user) {
      return json(404, { error: 'user not found' });
    }

    const status = await tryOrLog('fetch user status', () => fetchUserStatus(user_id));
    return json(200, { ...user, status });
  }

  return json(404, { error: 'not found' });
}

function json(statusCode, body) {
  return { statusCode, body };
}

module.exports = {
  handleRequest,
  json
};
