import type { User } from "@acme/types";

export function renderUserTable(users: User[]): string {
  const rows = users
    .map(user => `<tr><td>${user.fullName}</td><td>${user.email}</td><td>${user.role}</td></tr>`)
    .join("");
  return `<table><tbody>${rows}</tbody></table>`;
}
