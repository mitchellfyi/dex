import type { User } from "@acme/types";

export function serializeUser(user: User) {
  return {
    id: user.id,
    email: user.email,
    name: user.fullName,
    role: user.role,
    active: user.active
  };
}
