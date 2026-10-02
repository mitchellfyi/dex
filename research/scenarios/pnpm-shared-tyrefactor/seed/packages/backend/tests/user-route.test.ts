import { serializeUser } from "../src/user-route";

const user = {
  id: "u1",
  email: "ada@example.com",
  fullName: "Ada Lovelace",
  role: "admin",
  active: true
};

serializeUser(user);
