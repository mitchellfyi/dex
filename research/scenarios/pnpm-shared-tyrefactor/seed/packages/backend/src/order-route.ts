import type { OrderWithUser } from "@acme/types";

export function serializeOrder(order: OrderWithUser) {
  return {
    id: order.id,
    userId: order.userId,
    customerName: order.user.fullName,
    totalCents: order.totalCents,
    status: order.status
  };
}
