import type { User } from "@acme/types";
import { userInitials } from "@acme/types";

export function renderUserCard(user: User): string {
  const status = user.active ? "Active" : "Disabled";
  return `<article data-user="${user.id}"><strong>${user.fullName}</strong><span>${user.email}</span><small>${userInitials(user)} ${status}</small></article>`;
}
