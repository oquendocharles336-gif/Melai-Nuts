// How a HitPay refund answer is recorded. Two mappers on purpose:
//
//   SEND  (POST /v1/refund):     a 4xx means HitPay refused to create the refund, so no money
//                                moved -> "failed" (the refund stays approved and may be sent again).
//   CHECK (GET /v1/refund/{id}): the refund ALREADY EXISTS at HitPay. A 4xx here (401 bad key,
//                                404, 429 rate limit...) says nothing about the money, so it is
//                                "unknown" and the attempt stays pending. Only an explicit refund
//                                status from HitPay ("failed" / "cancelled" / "rejected") may close
//                                it as failed — closing it otherwise would allow a second send while
//                                HitPay may already have paid the first.
//
// Same rules as admin/app/Services/HitPay/HitPayRefundService.php (sendOutcome / checkOutcome).

export type Outcome = { status: "succeeded" | "pending" | "failed" | "unknown"; refundId?: string; error?: string };

const SUCCEEDED = ["succeeded", "success", "completed", "refunded"];
const FAILED = ["failed", "cancelled", "canceled", "rejected"];

function fromRefundBody(body: Record<string, unknown>, requireId: boolean): Outcome {
  const id = typeof body.id === "string" && body.id !== "" ? body.id : undefined;
  const s = String(body.status ?? "").toLowerCase();
  if (requireId && !id) return { status: "unknown" };
  if (SUCCEEDED.includes(s)) return id ? { status: "succeeded", refundId: id } : { status: "succeeded" };
  if (FAILED.includes(s)) return { status: "failed", ...(id ? { refundId: id } : {}), error: `HitPay refund ${s}` };
  if (!id && s === "") return { status: "unknown" };
  return id ? { status: "pending", refundId: id } : { status: "pending" };
}

/** SEND: maps the answer to POST /v1/refund. */
export function sendOutcomeOf(httpStatus: number, body: Record<string, unknown> | null): Outcome {
  if (httpStatus >= 200 && httpStatus < 300 && body && typeof body === "object") {
    return fromRefundBody(body, true);
  }
  if (httpStatus >= 400 && httpStatus < 500) {
    const msg = typeof body?.message === "string" ? body.message : `HitPay refused the refund (HTTP ${httpStatus}).`;
    return { status: "failed", error: msg.slice(0, 250) };
  }
  return { status: "unknown" };
}

/** CHECK: maps the answer to GET /v1/refund/{id}. Any non-2xx answer is "unknown". */
export function checkOutcomeOf(httpStatus: number, body: Record<string, unknown> | null): Outcome {
  if (httpStatus >= 200 && httpStatus < 300 && body && typeof body === "object") {
    return fromRefundBody(body, false);
  }
  return { status: "unknown" };
}
