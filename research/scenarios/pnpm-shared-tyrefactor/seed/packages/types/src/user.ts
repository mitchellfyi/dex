export type UserRole = "admin" | "member" | "viewer";

export interface User {
  id: string;
  email: string;
  fullName: string;
  role: UserRole;
  active: boolean;
}

export function userInitials(user: User): string {
  return user.fullName
    .split(/\s+/)
    .filter(Boolean)
    .map(part => part[0].toUpperCase())
    .join("")
    .slice(0, 2);
}
