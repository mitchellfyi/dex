import type { OrderWithUser } from "@acme/types";

export function renderOrderSummary(order: OrderWithUser): string {
  const dollars = (order.totalCents / 100).toFixed(2);
  return `${order.user.fullName} paid $${dollars} for order ${order.id}`;
}
