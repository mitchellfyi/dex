Build a Node.js/Express REST API that implements JWT-based authentication with role-based access control. Requirements:

1. **User Registration** — `POST /auth/register`
   - Accepts `{ email, password, name }` in the request body
   - Hash passwords using bcrypt before storing
   - Validate password strength: minimum 8 characters, must contain at least one uppercase letter, one lowercase letter, and one number
   - Validate email format
   - Return 409 if email is already registered
   - Return 201 with the created user (excluding password) on success

2. **Login** — `POST /auth/login`
   - Accepts `{ email, password }`
   - Return 401 for invalid credentials
   - On success, return a JWT access token (short-lived, e.g. 15 minutes) and a refresh token (longer-lived, e.g. 7 days)
   - The JWT payload should contain the user's ID, email, and role — but never the password

3. **Token Refresh** — `POST /auth/refresh`
   - Accepts `{ refreshToken }`
   - Validate the refresh token and return a new access token
   - Return 401 if the refresh token is invalid or expired

4. **Protected Routes** (require valid JWT in `Authorization: Bearer <token>` header):
   - `GET /me` — return the current authenticated user's profile
   - `PUT /me` — update the current user's name or email
   - Return 401 if no token or invalid token is provided

5. **Role-Based Access Control (RBAC)**:
   - Users have a `role` field: either `"user"` (default) or `"admin"`
   - `GET /users` — admin only, returns list of all users (without passwords)
   - `DELETE /users/:id` — admin only, deletes a user by ID
   - Return 403 if a non-admin user attempts these endpoints

6. **Storage**: Use in-memory storage (an array or Map). No database required. Optionally seed one admin user on startup (e.g. admin@example.com / Admin123!).

7. **Configuration**: Read the JWT secret and port from environment variables (`JWT_SECRET`, `PORT`). Provide sensible defaults.

8. **Project Structure**: Include a `package.json` with a `test` script. Organize code into separate files for routes, middleware, etc.

9. **Tests**: Write comprehensive tests covering:
   - Registration (valid, duplicate email, weak password)
   - Login (valid, wrong password, nonexistent email)
   - Protected route access (with token, without token, expired token)
   - RBAC (admin vs regular user access)
   - Token refresh flow
   - Use supertest or a similar HTTP testing library
