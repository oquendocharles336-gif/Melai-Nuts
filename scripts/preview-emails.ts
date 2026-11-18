// Writes every Melai Nuts account e-mail to an .html (and .txt) file so it can be opened in a
// browser, or pasted into Litmus / Email on Acid / a Gmail "send to myself" test.
//
//   deno run --allow-write --allow-env scripts/preview-emails.ts [out-dir]   (default: build/email-previews)
//
// Uses EMAIL_LOGO_URL, EMAIL_FOOTER_ADDRESS, EMAIL_SUPPORT_CONTACT and PUBLIC_SITE_URL from the
// environment when set, so the preview looks like production. Links point at PUBLIC_SITE_URL
// with a placeholder token; nothing is sent.
import {
  renderEmailChangeConfirmEmail,
  renderEmailChangeNoticeEmail,
  renderMfaEnrolledEmail,
  renderPasswordResetEmail,
  renderVerificationEmail,
  formatWhen,
} from "../supabase/functions/_shared/email-template.ts";

const out = (Deno.args[0] ?? "build/email-previews").replace(/\/+$/, "");
const env = (n: string) => Deno.env.get(n) || undefined;
const site = (env("PUBLIC_SITE_URL") ?? "https://your-domain.example").replace(/\/+$/, "");
const brand = {
  logoUrl: env("EMAIL_LOGO_URL"),
  businessAddress: env("EMAIL_FOOTER_ADDRESS"),
  supportContact: env("EMAIL_SUPPORT_CONTACT"),
  siteUrl: site,
  name: env("PREVIEW_NAME") ?? "Maria Santos", // greeting; set PREVIEW_NAME="" to see "Hi there,"
};
const token = "PREVIEW-TOKEN-PREVIEW-TOKEN-PREVIEW-TOKEN-00";
const when = formatWhen(new Date());
const emails = {
  "1-email-verification": renderVerificationEmail({ ...brand, code: "482913", expiresMinutes: 10 }),
  "2-password-reset": renderPasswordResetEmail({ ...brand, url: `${site}/auth/action?mode=resetPassword&token=${token}`, expiresMinutes: 30 }),
  "3a-email-change-confirm-new-address": renderEmailChangeConfirmEmail({ ...brand, url: `${site}/auth/action?mode=confirmEmail&token=${token}`, newEmail: "new.address@your-domain.example", expiresMinutes: 60 }),
  "3b-email-change-notice-old-address": renderEmailChangeNoticeEmail({ ...brand, newEmail: "new.address@your-domain.example", cancelUrl: `${site}/auth/action?mode=cancelEmailChange&token=${token}`, secureUrl: `${site}/?panel=reset-password`, when, expiresMinutes: 60 }),
  "4-mfa-enrolled-notice": renderMfaEnrolledEmail({ ...brand, when, device: "Chrome on Windows", secureUrl: `${site}/?panel=reset-password` }),
};
await Deno.mkdir(out, { recursive: true });
for (const [name, m] of Object.entries(emails)) {
  await Deno.writeTextFile(`${out}/${name}.html`, m.html);
  await Deno.writeTextFile(`${out}/${name}.txt`, `Subject: ${m.subject}\n\n${m.text}\n`);
  console.log(`${out}/${name}.html  —  ${m.subject}`);
}
