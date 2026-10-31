// Maps HitPay's payment_type onto payments.method codes (the check constraint in
// supabase/migrations/20261031050000_hitpay_payment_method_codes.sql lists them).
//
// The names come from HitPay's Philippines list:
// https://docs.hitpayapp.com/apis/guide/payment-methods-reference
// Matched on parts of the name because HitPay's docs do not spell out how
// payment_type is written in the webhook. First match wins, so the more specific
// names come first and "card" comes last.
const CODES: ReadonlyArray<readonly [string, string]> = [
  ["qrph", "qrph"],
  ["qr_ph", "qrph"],
  ["gcash", "gcash"],
  ["paymaya", "maya"],
  ["maya", "maya"],
  ["grab", "grabpay"],
  ["shopee_pay_later", "spaylater"],
  ["spaylater", "spaylater"],
  ["shopee", "shopeepay"],
  ["billease", "billease"],
  ["wechat", "wechat"],
  ["upay_online", "unionbank"],
  ["unionbank", "unionbank"],
  ["instapay", "instapay"],
  ["upay_pchc", "pesonet"],
  ["pesonet", "pesonet"],
  ["bayad", "bayad"],
  ["ecpy", "ecpay"],
  ["ecpay", "ecpay"],
  ["plwn", "palawan"],
  ["palawan", "palawan"],
  ["card", "card"],
];

/** The payments.method code of a HitPay payment_type, or null when it is not one we know. */
export function methodCode(paymentType: unknown): string | null {
  const type = typeof paymentType === "string" ? paymentType.trim().toLowerCase().replace(/[\s-]+/g, "_") : "";
  return CODES.find(([name]) => type.includes(name))?.[1] ?? null;
}

/**
 * The code to store with a result. A completed payment always gets its real method,
 * or "online" when the method is unknown, so it never keeps the "card" placeholder.
 * A failed payment says nothing certain, so an unknown method leaves the stored one.
 */
export function methodForResult(status: unknown, paymentType: unknown): string | null {
  const code = methodCode(paymentType);
  return status === "completed" ? code ?? "online" : code;
}
