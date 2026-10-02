import type { User } from "@acme/types";

export function menuLabel(user: User): string {
  return `${user.fullName} (${user.role})`;
}
