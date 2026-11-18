// Sends transactional e-mail through Resend's HTTPS API (https://resend.com/docs/api-reference/emails/send-email).
//
// Why HTTPS and not SMTP from here: hosted Edge Functions are not a reliable place to open
// SMTP connections (port 25 is blocked on most clouds and submission ports are often
// filtered). Use the SAME Resend account / verified domain for Supabase Dashboard > Auth >
// SMTP Settings (host smtp.resend.com, port 465 or 587, user "resend", password = the API key),
// so every Melai Nuts e-mail comes from one authenticated domain with SPF, DKIM and DMARC.
//
// Secrets: RESEND_API_KEY, EMAIL_FROM (e.g. "Melai Nuts <no-reply@your-domain>"),
// optional EMAIL_REPLY_TO.
import type { RenderedEmail } from "./email-template.ts";

export type SendMail = (to: string, email: RenderedEmail) => Promise<void>;

export function resendMailer(apiKey: string, from: string, replyTo: string | undefined, fetchFn: typeof fetch = fetch): SendMail {
  return async (to, email) => {
    if (!apiKey || !from) throw new Error("e-mail is not configured (RESEND_API_KEY / EMAIL_FROM)");
    const res = await fetchFn("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from,
        to: [to],
        subject: email.subject,
        html: email.html,
        text: email.text,
        ...(replyTo ? { reply_to: replyTo } : {}),
        headers: { "X-Entity-Ref-ID": crypto.randomUUID() }, // stops Gmail threading codes together
      }),
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 200)}`);
  };
}
