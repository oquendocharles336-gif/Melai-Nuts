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
//
// GMAIL (no domain of your own): set SMTP_USER (the Gmail address) and SMTP_PASSWORD (a
// Google App Password, NOT the account password). Mail then goes through smtp.gmail.com on
// port 465 (implicit TLS); Supabase Edge Functions block outbound 25 and 587, 465 is open.
// Google signs it (SPF/DKIM pass for gmail.com), no DNS work. Gmail sends ~500 mails/day.
// EMAIL_FROM is optional here and must be the same Gmail address (Gmail rewrites any other).
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

export interface SmtpConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  from: string;
  replyTo?: string;
}

export interface SmtpMessage {
  from: string;
  to: string;
  subject: string;
  html: string;
  text: string;
  replyTo?: string;
  headers: Record<string, string>;
}

export type SmtpSend = (config: SmtpConfig, message: SmtpMessage) => Promise<void>;

// Real transport: nodemailer over implicit TLS. Loaded lazily so tests and the Resend path
// never import it.
export const nodemailerSend: SmtpSend = async (config, message) => {
  const nodemailer = (await import("npm:nodemailer@6.9.16")).default;
  const transport = nodemailer.createTransport({
    host: config.host,
    port: config.port,
    secure: config.port === 465,
    auth: { user: config.user, pass: config.password },
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 15000,
  });
  await transport.sendMail(message);
};

export function smtpMailer(config: SmtpConfig, send: SmtpSend = nodemailerSend): SendMail {
  return async (to, email) => {
    if (!config.user || !config.password || !config.from) {
      throw new Error("e-mail is not configured (SMTP_USER / SMTP_PASSWORD)");
    }
    await send(config, {
      from: config.from,
      to,
      subject: email.subject,
      html: email.html,
      text: email.text,
      ...(config.replyTo ? { replyTo: config.replyTo } : {}),
      headers: { "X-Entity-Ref-ID": crypto.randomUUID() },
    });
  };
}

// Picks the sender from the secrets: SMTP_USER + SMTP_PASSWORD (Gmail by default) win,
// otherwise Resend. One place, so every function sends the same way.
export function mailerFromEnv(env: (name: string) => string | undefined, send: SmtpSend = nodemailerSend): SendMail {
  const user = (env("SMTP_USER") ?? "").trim();
  const password = (env("SMTP_PASSWORD") ?? "").replace(/\s+/g, ""); // App Passwords are shown with spaces
  const replyTo = env("EMAIL_REPLY_TO")?.trim() || undefined;
  if (user && password) {
    const name = (env("EMAIL_FROM_NAME") ?? "Melai Nuts").trim() || "Melai Nuts";
    return smtpMailer({
      host: (env("SMTP_HOST") ?? "smtp.gmail.com").trim(),
      port: Number(env("SMTP_PORT") ?? "465") || 465,
      user,
      password,
      from: env("EMAIL_FROM")?.trim() || `${name} <${user}>`,
      replyTo,
    }, send);
  }
  return resendMailer(env("RESEND_API_KEY") ?? "", withSenderName(env("EMAIL_FROM") ?? "", env("EMAIL_FROM_NAME")), replyTo);
}

/** "no-reply@x" -> "Melai Nuts <no-reply@x>", so the inbox shows the shop's name. A from that already has a name is kept. */
export function withSenderName(from: string, name?: string): string {
  const f = from.trim();
  if (f === "" || f.includes("<")) return f;
  const n = (name ?? "Melai Nuts").replace(/[<>"\r\n]/g, "").trim() || "Melai Nuts";
  return `${n} <${f}>`;
}
