import type { User } from "@acme/types";

export function auditActor(user: User): string {
  return `${user.fullName} <${user.email}>`;
}
