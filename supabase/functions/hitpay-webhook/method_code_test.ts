// deno test supabase/functions/hitpay-webhook/method_code_test.ts
import { methodCode, methodForResult } from "./method_code.ts";

function eq(actual: unknown, expected: unknown, label: string) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}

Deno.test("every method on HitPay's Philippines list gets its own code", () => {
  const expected: Record<string, string> = {
    card_cybersource: "card",
    card_present_cybersource: "card",
    gcash: "gcash",
    gcash_qr: "gcash",
    qrph_netbank: "qrph",
    grabpay_direct: "grabpay",
    shopee_pay: "shopeepay",
    shopee_pay_later: "spaylater",
    billease: "billease",
    wechat_pay: "wechat",
    upay_online: "unionbank",
    upay_instapay: "instapay",
    upay_pchc: "pesonet",
    upay_bayad: "bayad",
    upay_ecpy: "ecpay",
    upay_plwn: "palawan",
  };
  for (const [type, code] of Object.entries(expected)) eq(methodCode(type), code, type);
});

Deno.test("capitals and spaces in the name do not matter", () => {
  eq(methodCode("QRPH"), "qrph", "QRPH");
  eq(methodCode("QR Ph"), "qrph", "QR Ph");
  eq(methodCode("GCash"), "gcash", "GCash");
  eq(methodCode("PayMaya"), "maya", "PayMaya");
  eq(methodCode("Shopee Pay Later"), "spaylater", "Shopee Pay Later");
  eq(methodCode("Credit Card"), "card", "Credit Card");
});

Deno.test("an unknown or missing type has no code", () => {
  for (const type of ["something_new", "", null, undefined, 12]) eq(methodCode(type), null, String(type));
});

Deno.test("a completed payment never keeps the card placeholder", () => {
  eq(methodForResult("completed", "qrph_netbank"), "qrph", "known");
  eq(methodForResult("completed", "something_new"), "online", "unknown");
  eq(methodForResult("completed", undefined), "online", "missing");
});

Deno.test("a failed payment with an unknown method leaves the stored one", () => {
  eq(methodForResult("failed", "gcash"), "gcash", "known");
  eq(methodForResult("failed", undefined), null, "missing");
});
