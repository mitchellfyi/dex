Build a blog API with Express.js and SQLite (use `better-sqlite3` or `sqlite3` package).

**Database schema:**
- `users` table: id (UUID), username (unique), email (unique), bio, created_at
- `posts` table: id (UUID), title, content, author_id (FK to users), published (boolean), created_at, updated_at
- `tags` table: id, name (unique)
- `post_tags` junction table: post_id, tag_id (many-to-many)

**Endpoints:**
- POST /users — create user
- GET /posts — list published posts (with author info and tags)
- POST /posts — create post (requires author_id)
- GET /posts/:id — get post with author and tags
- PUT /posts/:id — update post
- DELETE /posts/:id — delete post (cascade post_tags)
- POST /posts/:id/tags — add tags to a post
- GET /posts?tag=javascript — filter posts by tag
- GET /posts?author=username — filter posts by author
- GET /users/:id/posts — get all posts by a user

**Requirements:**
- Database file stored at `./data/blog.db`
- Create tables on startup (migration/init script)
- Use parameterized queries (no SQL injection)
- Return proper relationships (post includes author object and tags array)
- Pagination on list endpoints
- Include comprehensive tests
- Tests should use a separate test database (not overwrite the main one)
