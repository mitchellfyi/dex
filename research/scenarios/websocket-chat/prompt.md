Build a real-time WebSocket chat server in Node.js. Requirements:

1. **WebSocket Server**:
   - Use the `ws` package (or `socket.io`) for WebSocket connections
   - Server listens on a configurable port via `PORT` environment variable (default 3000)
   - Export the server or make it startable via `node server.js` (or `node index.js`)

2. **Chat Rooms**:
   - Users can join a named room (e.g. "general", "random")
   - Messages sent in a room are broadcast only to users in that same room
   - Users can leave a room and join a different one
   - Users can list all active rooms (rooms with at least one user)

3. **Nicknames**:
   - Users join with a nickname
   - Nicknames are displayed with each message
   - Reject duplicate nicknames within the same room (optional but preferred)

4. **Message History**:
   - Keep the last 50 messages per room in memory
   - When a user joins a room, send them the recent message history
   - Each message should include: sender nickname, content, timestamp, and room

5. **System Messages**:
   - Broadcast a system message when a user joins a room (e.g. "Alice joined the room")
   - Broadcast a system message when a user leaves a room
   - System messages should be distinguishable from regular chat messages

6. **Disconnect Handling**:
   - When a client disconnects, notify other users in their room
   - Clean up the user from the room's user list
   - Handle unexpected disconnections gracefully (no server crash)

7. **Message Protocol** (JSON-based):
   - Join: `{ "type": "join", "room": "<room-name>", "nickname": "<name>" }`
   - Message: `{ "type": "message", "content": "<text>" }`
   - Leave: `{ "type": "leave" }`
   - List rooms: `{ "type": "list_rooms" }`
   - Server responses include a `type` field (e.g. "message", "system", "history", "room_list", "error")

8. Include `package.json` with appropriate dependencies and scripts.

9. Include comprehensive tests covering:
   - Connection and disconnection lifecycle
   - Joining rooms and sending messages
   - Room isolation (messages don't leak across rooms)
   - Message history delivery to new joiners
   - Multiple concurrent clients
   - Error handling for malformed messages
