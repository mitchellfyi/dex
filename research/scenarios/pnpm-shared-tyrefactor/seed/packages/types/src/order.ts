import type { User } from "./user";

export interface Order {
  id: string;
  userId: string;
  totalCents: number;
  status: "draft" | "paid" | "cancelled";
}

export interface OrderWithUser extends Order {
  user: User;
}
