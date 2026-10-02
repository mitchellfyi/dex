const users = [
  { id: 'u1', email: 'ada@example.com', display_name: 'Ada Lovelace' },
  { id: 'u2', email: 'grace@example.com', display_name: 'Grace Hopper' }
];

const activity_logs = [
  { id: 'a1', user_id: 'u1', activity_type: 'login', occurred_at: '2026-05-03T10:00:00.000Z' },
  { id: 'a2', user_id: 'u1', activity_type: 'export', occurred_at: '2026-05-20T14:30:00.000Z' },
  { id: 'a3', user_id: 'u1', activity_type: 'login', occurred_at: '2026-06-02T09:00:00.000Z' },
  { id: 'a4', user_id: 'u2', activity_type: 'login', occurred_at: '2026-05-07T11:00:00.000Z' }
];

function find_user_by_id(id) {
  return users.find(user => user.id === id) || null;
}

function list_recent_activity(user_id, limit = 5) {
  return activity_logs
    .filter(row => row.user_id === user_id)
    .sort((left, right) => right.occurred_at.localeCompare(left.occurred_at))
    .slice(0, limit);
}

module.exports = {
  find_user_by_id,
  list_recent_activity,
  _tables: {
    users,
    activity_logs
  }
};
