// Every Melai Nuts account e-mail, on one shared layout (HTML + plain text):
//   renderVerificationEmail       6-digit sign-up code
//   renderPasswordResetEmail      "Reset your password" button
//   renderEmailChangeConfirmEmail to the NEW address: "Confirm new email" button
//   renderEmailChangeNoticeEmail  to the OLD address: "Was this you?" + cancel / secure buttons
//   renderMfaEnrolledEmail        "A second sign-in step was added" security notice
//
// Built for real inboxes (Gmail, Outlook desktop + web, Apple Mail):
//   * table layout, inline CSS only (no <style>: Gmail drops it in many clients), 600 px max
//     width that shrinks on phones, web-safe font stack;
//   * one primary action: a "bulletproof" button (VML for Outlook desktop) or a large, spaced,
//     copyable code. Long URLs are never printed in the HTML; the text part has the link;
//   * dark-mode safe: every block has a solid bgcolor and text meets 4.5:1 on it, so clients that
//     invert colours (Gmail app, Outlook.com) keep it readable;
//   * hidden preheader, a calm subject without spam words, no Firebase wording.
//
// Brand: lib/core/theme/app_colors.dart — cream canvas #FFF9F0, warm brown ink #3B2114 / #1F120B,
// terracotta #BF4409 (button text white: 4.9:1), border #F3E1C4, muted #6E5E50.

export type Brand = {
  /** Absolute https URL of a PNG/JPG logo (EMAIL_LOGO_URL). SVG is not shown by most clients. */
  logoUrl?: string;
  /** Footer lines (EMAIL_FOOTER_ADDRESS, EMAIL_SUPPORT_CONTACT). Omitted when not set. */
  businessAddress?: string;
  supportContact?: string;
  /** The website (PUBLIC_SITE_URL): Privacy / Terms links in the footer. */
  siteUrl?: string;
};

export type VerificationEmailInput = Brand & { code: string; expiresMinutes: number };
export type RenderedEmail = { subject: string; html: string; text: string };

export const BRAND = {
  name: "Melai Nuts",
  primary: "#BF4409",
  ink: "#1F120B",
  brown: "#3B2114",
  canvas: "#FFF9F0",
  card: "#FFFFFF",
  border: "#F3E1C4",
  muted: "#6E5E50",
  codeBg: "#FFE6C2",
  noteBg: "#FFF6E8",
};
const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const httpsUrl = (u: string | undefined): string | null => (u && /^https:\/\/[^\s"'<>]+$/.test(u.trim()) ? u.trim() : null);
const siteBase = (u: string | undefined): string | null => httpsUrl(u)?.replace(/\/+$/, "") ?? null;
const minutesText = (m: number) => {
  const n = Math.max(1, Math.round(m));
  if (n % 60 === 0 && n >= 60) return `${n / 60} hour${n === 60 ? "" : "s"}`;
  return `${n} minute${n === 1 ? "" : "s"}`;
};

type Action =
  | { kind: "code"; code: string }
  | { kind: "button"; label: string; url: string }
  | { kind: "none" };

type Layout = Brand & {
  subject: string;
  preheader: string;
  heading: string;
  /** Plain-text paragraphs (escaped here). */
  intro: string[];
  action: Action;
  /** A second, quieter button under the main one (e.g. "Not you? Secure your account"). */
  secondary?: { label: string; url: string; lead?: string };
  /** Bold line under the action, e.g. "This link expires in 30 minutes." */
  expiry?: string;
  /** Key/value facts in a soft box (time, device). */
  facts?: Array<[string, string]>;
  ignore?: string;
  /** Why the person got this e-mail (footer). */
  reason: string;
};

function button(label: string, url: string, primary: boolean): string {
  const bg = primary ? BRAND.primary : BRAND.card;
  const fg = primary ? "#FFFFFF" : BRAND.brown;
  const border = primary ? BRAND.primary : BRAND.border;
  const href = esc(url);
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:0 auto"><tr><td align="center" bgcolor="${bg}" style="border-radius:999px;background:${bg};border:1px solid ${border}">
<!--[if mso]><v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="${href}" style="height:48px;v-text-anchor:middle;width:260px" arcsize="50%" strokecolor="${border}" fillcolor="${bg}"><w:anchorlock/><center style="color:${fg};font-family:Arial,sans-serif;font-size:16px;font-weight:bold">${esc(label)}</center></v:roundrect><![endif]-->
<!--[if !mso]><!--><a href="${href}" target="_blank" rel="noopener" style="display:inline-block;padding:14px 32px;font-family:${FONT};font-size:16px;line-height:20px;font-weight:700;color:${fg};text-decoration:none;border-radius:999px;mso-hide:all">${esc(label)}</a><!--<![endif]-->
</td></tr></table>`;
}

function renderLayout(l: Layout): RenderedEmail {
  const logoUrl = httpsUrl(l.logoUrl);
  const site = siteBase(l.siteUrl);
  const logo = logoUrl
    ? `<img src="${esc(logoUrl)}" width="56" height="56" alt="${BRAND.name} logo" style="display:block;border:0;outline:none;width:56px;height:56px;border-radius:14px;margin:0 auto">`
    : `<div role="img" aria-label="${BRAND.name}" style="width:56px;height:56px;line-height:56px;margin:0 auto;border-radius:28px;background:${BRAND.primary};color:#FFFFFF;font-family:${FONT};font-size:24px;font-weight:700;text-align:center">M</div>`;
  const p = (t: string) => `<p style="margin:0 0 12px 0;font-family:${FONT};font-size:16px;line-height:24px;color:${BRAND.ink};text-align:center">${esc(t)}</p>`;

  let action = "";
  if (l.action.kind === "code") {
    const c = l.action.code;
    action = `<tr><td align="center" style="padding:12px 32px 20px 32px">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="background:${BRAND.codeBg};border-radius:12px" bgcolor="${BRAND.codeBg}">
<tr><td align="center" style="padding:16px 28px;font-family:'Courier New',Courier,monospace;font-size:36px;line-height:44px;font-weight:700;letter-spacing:8px;color:${BRAND.ink}">${esc(c.slice(0, 3))} ${esc(c.slice(3))}</td></tr>
</table></td></tr>`;
  } else if (l.action.kind === "button") {
    action = `<tr><td align="center" style="padding:12px 32px 20px 32px">${button(l.action.label, l.action.url, true)}</td></tr>`;
  }
  const facts = l.facts?.length
    ? `<tr><td style="padding:0 32px 16px 32px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${BRAND.noteBg}" style="background:${BRAND.noteBg};border-radius:12px">${
      l.facts.map(([k, v]) => `<tr><td style="padding:10px 16px 0 16px;font-family:${FONT};font-size:13px;line-height:18px;color:${BRAND.muted}">${esc(k)}</td></tr><tr><td style="padding:2px 16px 10px 16px;font-family:${FONT};font-size:15px;line-height:22px;color:${BRAND.ink};font-weight:600">${esc(v)}</td></tr>`).join("")
    }</table></td></tr>`
    : "";
  const secondary = l.secondary
    ? `<tr><td align="center" style="padding:0 32px 20px 32px">${l.secondary.lead ? `<p style="margin:0 0 10px 0;font-family:${FONT};font-size:14px;line-height:21px;color:${BRAND.muted};text-align:center">${esc(l.secondary.lead)}</p>` : ""}${button(l.secondary.label, l.secondary.url, false)}</td></tr>`
    : "";
  const footerLines = [BRAND.name, l.businessAddress, l.supportContact]
    .filter((x): x is string => typeof x === "string" && x.trim() !== "").map((x) => esc(x.trim()));
  const legal = site
    ? `<br><a href="${esc(site)}/privacy" style="color:${BRAND.muted};text-decoration:underline">Privacy Policy</a> &nbsp;·&nbsp; <a href="${esc(site)}/terms" style="color:${BRAND.muted};text-decoration:underline">Terms</a>`
    : "";

  const html = `<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="format-detection" content="telephone=no, date=no, address=no, email=no">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>${esc(l.subject)}</title>
<!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><![endif]-->
</head>
<body style="margin:0;padding:0;background:${BRAND.canvas};-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%">
<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;font-size:1px;line-height:1px;color:${BRAND.canvas}">${esc(l.preheader)}&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BRAND.canvas}" bgcolor="${BRAND.canvas}">
<tr><td align="center" style="padding:32px 12px">
<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;background:${BRAND.card};border:1px solid ${BRAND.border};border-radius:20px" bgcolor="${BRAND.card}">
<tr><td align="center" style="padding:32px 32px 4px 32px">${logo}
<div style="margin-top:10px;font-family:${FONT};font-size:15px;font-weight:700;letter-spacing:.04em;color:${BRAND.brown}">${BRAND.name}</div>
</td></tr>
<tr><td style="padding:20px 32px 4px 32px">
<h1 style="margin:0 0 14px 0;font-family:${FONT};font-size:24px;line-height:30px;font-weight:700;color:${BRAND.ink};text-align:center">${esc(l.heading)}</h1>
${l.intro.map(p).join("\n")}
</td></tr>
${action}
${l.expiry ? `<tr><td style="padding:0 32px 16px 32px;font-family:${FONT};font-size:15px;line-height:22px;color:${BRAND.ink};text-align:center"><strong>${esc(l.expiry)}</strong></td></tr>` : ""}
${facts}
${secondary}
<tr><td style="padding:4px 32px 28px 32px;font-family:${FONT};font-size:14px;line-height:21px;color:${BRAND.muted};text-align:center">${esc(l.ignore ?? "If you didn't request this, you can safely ignore this email.")}<br>${BRAND.name} will never ask for your password or a code by phone, chat or text message.</td></tr>
<tr><td style="padding:20px 32px;border-top:1px solid ${BRAND.border};font-family:${FONT};font-size:12px;line-height:18px;color:${BRAND.muted};text-align:center">${footerLines.join("<br>")}<br>${esc(l.reason)}${legal}</td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr>
</table>
</body>
</html>`;

  const text = [
    BRAND.name,
    "",
    l.heading,
    "",
    ...l.intro.flatMap((t) => [t, ""]),
    ...(l.action.kind === "code" ? [`Your code: ${l.action.code}`, ""] : []),
    ...(l.action.kind === "button" ? [`${l.action.label}: ${l.action.url}`, ""] : []),
    ...(l.expiry ? [l.expiry, ""] : []),
    ...(l.facts ?? []).map(([k, v]) => `${k}: ${v}`),
    ...(l.facts?.length ? [""] : []),
    ...(l.secondary ? [`${l.secondary.lead ? l.secondary.lead + " " : ""}${l.secondary.label}: ${l.secondary.url}`, ""] : []),
    l.ignore ?? "If you didn't request this, you can safely ignore this email.",
    `${BRAND.name} will never ask for your password or a code by phone, chat or text message.`,
    "",
    "--",
    ...[BRAND.name, l.businessAddress, l.supportContact].filter((x): x is string => typeof x === "string" && x.trim() !== "").map((x) => x.trim()),
    l.reason,
    ...(site ? [`Privacy Policy: ${site}/privacy`, `Terms: ${site}/terms`] : []),
  ].join("\n");

  return { subject: l.subject, html, text };
}

// --- The four e-mails ------------------------------------------------------------------------

export function renderVerificationEmail(input: VerificationEmailInput): RenderedEmail {
  if (!/^\d{6}$/.test(input.code)) throw new Error("code must be 6 digits");
  const expiry = `This code expires in ${minutesText(input.expiresMinutes)}.`;
  return renderLayout({
    ...input,
    subject: `Your ${BRAND.name} verification code: ${input.code}`,
    preheader: `Your code is ${input.code}. ${expiry}`,
    heading: "Confirm your email",
    intro: [`Enter this code in the ${BRAND.name} app or website to finish creating your account.`],
    action: { kind: "code", code: input.code },
    expiry,
    ignore: "If you didn't request this, you can safely ignore this email. Your email address won't be used without this code.",
    reason: `You received this email because this address was used to create a ${BRAND.name} account.`,
  });
}

export type LinkEmailInput = Brand & { url: string; expiresMinutes: number };

export function renderPasswordResetEmail(input: LinkEmailInput): RenderedEmail {
  const url = httpsUrl(input.url) ?? (() => { throw new Error("url must be https"); })();
  const expiry = `This link expires in ${minutesText(input.expiresMinutes)} and works once.`;
  return renderLayout({
    ...input,
    subject: `Reset your ${BRAND.name} password`,
    preheader: `Choose a new password for your ${BRAND.name} account. ${expiry}`,
    heading: "Reset your password",
    intro: [`We got a request to reset the password for your ${BRAND.name} account. Tap the button to choose a new one.`],
    action: { kind: "button", label: "Reset password", url },
    expiry,
    ignore: "If you didn't request this, you can ignore this email: your password stays the same.",
    reason: `You received this email because a password reset was requested for your ${BRAND.name} account.`,
  });
}

export function renderEmailChangeConfirmEmail(input: LinkEmailInput & { newEmail: string }): RenderedEmail {
  const url = httpsUrl(input.url) ?? (() => { throw new Error("url must be https"); })();
  const expiry = `This link expires in ${minutesText(input.expiresMinutes)} and works once.`;
  return renderLayout({
    ...input,
    subject: `Confirm your new ${BRAND.name} email`,
    preheader: `Confirm ${input.newEmail} as the email for your ${BRAND.name} account.`,
    heading: "Confirm your new email",
    intro: [
      `You asked to use ${input.newEmail} for your ${BRAND.name} account.`,
      "Your email changes only after you confirm it.",
    ],
    action: { kind: "button", label: "Confirm new email", url },
    expiry,
    ignore: "If you didn't request this, you can ignore this email: nothing changes.",
    reason: `You received this email because this address was entered as the new email of a ${BRAND.name} account.`,
  });
}

export function renderEmailChangeNoticeEmail(
  input: Brand & { newEmail: string; cancelUrl: string; secureUrl: string; when: string; expiresMinutes: number },
): RenderedEmail {
  const cancel = httpsUrl(input.cancelUrl) ?? (() => { throw new Error("cancelUrl must be https"); })();
  const secure = httpsUrl(input.secureUrl) ?? (() => { throw new Error("secureUrl must be https"); })();
  return renderLayout({
    ...input,
    subject: `Was this you? Email change requested on ${BRAND.name}`,
    preheader: `Someone asked to change your ${BRAND.name} email to ${input.newEmail}.`,
    heading: "Was this you?",
    intro: [
      `Someone asked to change the email of your ${BRAND.name} account to ${input.newEmail}.`,
      "Nothing changes unless the new address is confirmed. If this wasn't you, stop the change now.",
    ],
    action: { kind: "button", label: "Stop this change", url: cancel },
    expiry: `You can stop it for the next ${minutesText(input.expiresMinutes)}.`,
    facts: [["Requested", input.when], ["New email", input.newEmail]],
    secondary: { lead: "Not you? Change your password too.", label: "Secure your account", url: secure },
    ignore: "If you made this change, you don't need to do anything.",
    reason: `You received this email because it is the current email of a ${BRAND.name} account.`,
  });
}

export function renderMfaEnrolledEmail(input: Brand & { when: string; device: string; secureUrl: string }): RenderedEmail {
  const secure = httpsUrl(input.secureUrl) ?? (() => { throw new Error("secureUrl must be https"); })();
  return renderLayout({
    ...input,
    subject: `Security notice: a second sign-in step was added to your ${BRAND.name} account`,
    preheader: "Two-step sign-in is now on for your account.",
    heading: "A second sign-in step was added",
    intro: [`Two-step sign-in (an authenticator app code) was turned on for your ${BRAND.name} account. From now on you'll enter a code after your password.`],
    action: { kind: "none" },
    facts: [["When", input.when], ["Browser / device", input.device]],
    secondary: { lead: "Not you? Someone may know your password.", label: "Secure your account", url: secure },
    ignore: "If this was you, you don't need to do anything.",
    reason: `You received this security notice because it is the email of a ${BRAND.name} account.`,
  });
}

/** "Nov 18, 2026, 3:41 PM (Philippine time)". */
export function formatWhen(d: Date, timeZone = "Asia/Manila"): string {
  const s = new Intl.DateTimeFormat("en-PH", { timeZone, day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit", hour12: true }).format(d);
  return timeZone === "Asia/Manila" ? `${s} (Philippine time)` : s;
}
