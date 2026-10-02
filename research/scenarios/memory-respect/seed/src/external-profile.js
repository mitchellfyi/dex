async function fetchUserStatus(user_id) {
  if (!user_id) {
    throw new Error('user_id is required');
  }
  return { user_id, risk_level: user_id === 'u2' ? 'review' : 'normal' };
}

module.exports = { fetchUserStatus };
