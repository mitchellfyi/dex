import { renderUserCard } from "../src/UserCard";

const user = {
  id: "u1",
  email: "ada@example.com",
  fullName: "Ada Lovelace",
  role: "admin",
  active: true
};

renderUserCard(user);
