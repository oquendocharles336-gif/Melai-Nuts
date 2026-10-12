// deno test supabase/functions/hitpay-refund/outcome_test.ts
import { checkOutcomeOf, sendOutcomeOf } from "./outcome.ts";

function assertEquals(actual: unknown, expected: unknown, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${msg} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

Deno.test("send: success / pending / refused / unknown", () => {
  assertEquals(sendOutcomeOf(200, { id: "rf1", status: "succeeded" }), { status: "succeeded", refundId: "rf1" });
  assertEquals(sendOutcomeOf(201, { id: "rf2", status: "pending" }), { status: "pending", refundId: "rf2" });
  assertEquals(sendOutcomeOf(200, { id: "rf3", status: "failed" }).status, "failed");
  assertEquals(sendOutcomeOf(422, { message: "Amount exceeds" }), { status: "failed", error: "Amount exceeds" });
  assertEquals(sendOutcomeOf(500, { message: "oops" }), { status: "unknown" });
  assertEquals(sendOutcomeOf(200, { status: "succeeded" }), { status: "unknown" }, "no refund id");
});

Deno.test("check: a non-2xx answer never closes the attempt as failed", () => {
  for (const http of [400, 401, 403, 404, 409, 422, 429, 500, 502, 503]) {
    assertEquals(checkOutcomeOf(http, { message: "nope", status: "failed" }), { status: "unknown" }, `HTTP ${http}`);
    assertEquals(checkOutcomeOf(http, null), { status: "unknown" }, `HTTP ${http} without body`);
  }
});

Deno.test("check: only an explicit HitPay refund status decides", () => {
  assertEquals(checkOutcomeOf(200, { id: "rf1", status: "succeeded" }), { status: "succeeded", refundId: "rf1" });
  assertEquals(checkOutcomeOf(200, { id: "rf1", status: "cancelled" }).status, "failed");
  assertEquals(checkOutcomeOf(200, { id: "rf1", status: "rejected" }).status, "failed");
  assertEquals(checkOutcomeOf(200, { id: "rf1", status: "processing" }), { status: "pending", refundId: "rf1" });
  assertEquals(checkOutcomeOf(200, {}), { status: "unknown" }, "empty answer");
});
