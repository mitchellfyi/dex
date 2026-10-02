Build a Node.js CLI todo application with the following features:

1. **Add a todo**: `node index.js add "Buy groceries"` — adds a new todo item
2. **List todos**: `node index.js list` — shows all todos with their status (pending/done)
3. **Complete a todo**: `node index.js complete <id>` — marks a todo as done
4. **Delete a todo**: `node index.js delete <id>` — removes a todo

Requirements:
- Store todos in a `todos.json` file in the current directory
- Each todo has: id (auto-incrementing integer), text, completed (boolean), createdAt (ISO timestamp)
- The `list` command should show the id, status indicator ([x] or [ ]), and text for each todo
- Handle edge cases: missing arguments, invalid IDs, empty todo list
- Include a package.json with a test script
- Write comprehensive tests covering all commands and edge cases
