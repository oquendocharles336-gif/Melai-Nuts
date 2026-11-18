// The Melai Nuts verification e-mail: one file, no links to click, just the code.
//
// Built for real inboxes: table layout, inline CSS only (Gmail strips <style> in many
// clients), a 600 px max width that shrinks on phones, web-safe fonts, and colours that stay
// readable when a client forces dark mode (solid backgrounds on every block, no text on
// transparent images). The code is also in the subject and the plain-text part, so it is
// readable in notifications and text-only clients.
//
// Brand colours: lib/core/theme/app_colors.dart (primary #BF4409, ink #1F120B, canvas #FFF9F0,
// border #F3E1C4, textSecondary #6E5E50).

export type VerificationEmailInput = {
  code: string;
  expiresMinutes: number;
  /** Absolute https URL of a PNG/JPG logo (EMAIL_LOGO_URL). SVG is not shown by most clients. */
  logoUrl?: string;
  /** Footer lines (EMAIL_FOOTER_ADDRESS, EMAIL_SUPPORT_CONTACT). Omitted when not set. */
  businessAddress?: string;
  supportContact?: string;
};

export type RenderedEmail = { subject: string; html: string; text: string };

const BRAND = {
  name: "Melai Nuts",
  primary: "#BF4409",
  ink: "#1F120B",
  canvas: "#FFF9F0",
  card: "#FFFFFF",
  border: "#F3E1C4",
  muted: "#6E5E50",
  codeBg: "#FFE6C2",
};

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export function renderVerificationEmail(input: VerificationEmailInput): RenderedEmail {
  if (!/^\d{6}$/.test(input.code)) throw new Error("code must be 6 digits");
  const minutes = Math.max(1, Math.round(input.expiresMinutes));
  const expiry = `This code expires in ${minutes} minute${minutes === 1 ? "" : "s"}.`;
  const subject = `Your ${BRAND.name} verification code: ${input.code}`;
  const spaced = `${input.code.slice(0, 3)} ${input.code.slice(3)}`;
  const logo = input.logoUrl && /^https:\/\//.test(input.logoUrl)
    ? `<img src="${esc(input.logoUrl)}" width="56" height="56" alt="${BRAND.name}" style="display:block;border:0;outline:none;width:56px;height:56px;border-radius:12px;margin:0 auto">`
    : `<div style="width:56px;height:56px;line-height:56px;margin:0 auto;border-radius:28px;background:${BRAND.primary};color:#FFFFFF;font-size:24px;font-weight:700;text-align:center">M</div>`;
  const footer = [BRAND.name, input.businessAddress, input.supportContact]
    .filter((l): l is string => typeof l === "string" && l.trim() !== "")
    .map((l) => esc(l.trim()))
    .join("<br>");

  const html = `<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="light only">
<meta name="supported-color-schemes" content="light only">
<title>${esc(subject)}</title>
</head>
<body style="margin:0;padding:0;background:${BRAND.canvas};-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:${BRAND.canvas}">Your code is ${input.code}. ${expiry}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BRAND.canvas}" bgcolor="${BRAND.canvas}">
<tr><td align="center" style="padding:32px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;background:${BRAND.card};border:1px solid ${BRAND.border};border-radius:16px" bgcolor="${BRAND.card}">
<tr><td align="center" style="padding:32px 32px 8px 32px">${logo}
<div style="margin-top:12px;font-family:Arial,Helvetica,sans-serif;font-size:18px;font-weight:700;color:${BRAND.ink}">${BRAND.name}</div>
</td></tr>
<tr><td style="padding:16px 32px 0 32px;font-family:Arial,Helvetica,sans-serif;color:${BRAND.ink}">
<h1 style="margin:0 0 12px 0;font-size:22px;line-height:28px;font-weight:700;color:${BRAND.ink};text-align:center">Confirm your email</h1>
<p style="margin:0;font-size:16px;line-height:24px;color:${BRAND.ink};text-align:center">Enter this code in the ${BRAND.name} app or website to finish creating your account.</p>
</td></tr>
<tr><td align="center" style="padding:24px 32px">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="background:${BRAND.codeBg};border-radius:12px" bgcolor="${BRAND.codeBg}">
<tr><td align="center" style="padding:16px 28px;font-family:'Courier New',Courier,monospace;font-size:36px;line-height:44px;font-weight:700;letter-spacing:8px;color:${BRAND.ink}">${spaced}</td></tr>
</table>
</td></tr>
<tr><td style="padding:0 32px 8px 32px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:22px;color:${BRAND.ink};text-align:center"><strong>${expiry}</strong></td></tr>
<tr><td style="padding:8px 32px 28px 32px;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:${BRAND.muted};text-align:center">
If you didn't request this, you can safely ignore this email. Your email address won't be used without this code.<br>
${BRAND.name} will never ask you for this code by phone, chat or text message.
</td></tr>
<tr><td style="padding:20px 32px;border-top:1px solid ${BRAND.border};font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:18px;color:${BRAND.muted};text-align:center">${footer}<br>You received this email because this address was used to create a ${BRAND.name} account.</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;

  const text = [
    `${BRAND.name}`,
    ``,
    `Confirm your email`,
    ``,
    `Your verification code is: ${input.code}`,
    ``,
    `Enter it in the ${BRAND.name} app or website to finish creating your account.`,
    expiry,
    ``,
    `If you didn't request this, you can safely ignore this email.`,
    `${BRAND.name} will never ask you for this code by phone, chat or text message.`,
    ``,
    `--`,
    ...[BRAND.name, input.businessAddress, input.supportContact].filter((l): l is string => typeof l === "string" && l.trim() !== "").map((l) => l.trim()),
  ].join("\n");

  return { subject, html, text };
}
