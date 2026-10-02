Add two features to the todo CLI:

1. `node index.js edit <id> <text>` replaces the text of an existing todo. It keeps the todo's id, completed status and createdAt. A missing id, a missing or empty text, or an id that does not exist is an error, handled the same way the other commands handle errors, and leaves `todos.json` unchanged.
2. `node index.js list --pending` lists only the todos that are not completed, in the same format as `list`. Plain `list` keeps showing every todo.

Keep the existing commands working, and add tests for both features.
