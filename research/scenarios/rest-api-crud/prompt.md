Build a REST API with Express.js for managing a bookshelf. Requirements:

1. **Endpoints**:
   - `GET /books` — list all books
   - `GET /books/:id` — get a single book by ID
   - `POST /books` — create a new book
   - `PUT /books/:id` — update a book
   - `DELETE /books/:id` — delete a book

2. **Book schema**: `{ id, title, author, isbn, createdAt }`
   - `title` is required, 1-200 characters
   - `author` is required, 1-100 characters
   - `isbn` is optional but must be valid format (10 or 13 digits) if provided

3. **Behavior**:
   - In-memory storage (no database required)
   - Return appropriate HTTP status codes (200, 201, 400, 404)
   - Return JSON error messages for validation failures
   - IDs are auto-generated UUIDs or incrementing integers

4. Include package.json, comprehensive tests, and proper error handling.
