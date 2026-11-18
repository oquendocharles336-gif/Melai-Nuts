// deno test supabase/functions/_shared/email_template_test.ts
// The shared layout of all four account e-mails: structure that real inboxes need, one primary
// action each, plain-text versions, no Firebase wording. Preview them with scripts/preview-emails.ts.
import {
  greetingName,
  renderEmailChangeConfirmEmail,
  renderEmailChangeNoticeEmail,
  renderMfaEnrolledEmail,
  renderPasswordResetEmail,
  renderVerificationEmail,
  type RenderedEmail,
} from "./email-template.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(msg);
}

const brand = {
  logoUrl: "https://shop.example.com/images/email-logo.png",
  businessAddress: "Calamba, Laguna",
  supportContact: "help@shop.example.com",
  siteUrl: "https://shop.example.com",
  name: "Maria Santos",
};
const link = "https://shop.example.com/auth/action?mode=resetPassword&token=" + "a".repeat(43);
const all: Array<[string, RenderedEmail]> = [
  ["verification", renderVerificationEmail({ ...brand, code: "048213", expiresMinutes: 10 })],
  ["reset", renderPasswordResetEmail({ ...brand, url: link, expiresMinutes: 30 })],
  ["change-confirm", renderEmailChangeConfirmEmail({ ...brand, url: link, newEmail: "new@shop.example.com", expiresMinutes: 60 })],
  ["change-notice", renderEmailChangeNoticeEmail({ ...brand, newEmail: "new@shop.example.com", cancelUrl: link, secureUrl: "https://shop.example.com/?panel=reset-password", when: "Nov 18, 2026, 3:41 PM", expiresMinutes: 60 })],
  ["mfa", renderMfaEnrolledEmail({ ...brand, when: "Nov 18, 2026, 3:41 PM", device: "Chrome on Windows", secureUrl: "https://shop.example.com/?panel=reset-password" })],
];

Deno.test("every e-mail: table layout, inline CSS, 600 px, preheader, logo with alt, footer with Privacy / Terms", () => {
  for (const [name, m] of all) {
    // Inline CSS is the base; the only <style> is the progressive dark-mode / phone block.
    assert(/<table role="presentation"/.test(m.html) && (m.html.match(/<style/gi) ?? []).length === 1, `${name}: tables + inline CSS`);
    assert(/style="[^"]*color:#1F120B/.test(m.html), `${name}: inline base colours`);
    assert(m.html.includes("prefers-color-scheme:dark") && m.html.includes('content="light dark"'), `${name}: dark mode`);
    assert(m.html.includes("[data-ogsc]"), `${name}: Outlook.com dark mode`);
    assert(m.html.includes("Hi Maria,") && m.text.includes("Hi Maria,"), `${name}: greeting by name`);
    assert(!/melai-nuts-app|oobCode|apiKey/i.test(m.subject + m.html + m.text), `${name}: no project id or Firebase params`);
    assert(m.html.includes("max-width:600px"), `${name}: 600 px`);
    assert(/display:none;max-height:0/.test(m.html), `${name}: hidden preheader`);
    assert(m.html.includes('alt="Melai Nuts logo"'), `${name}: logo alt text`);
    assert(m.html.includes("https://shop.example.com/privacy") && m.html.includes("https://shop.example.com/terms"), `${name}: legal links`);
    assert(m.html.includes("help@shop.example.com") && m.text.includes("help@shop.example.com"), `${name}: support e-mail`);
    assert(!/firebase/i.test(m.subject + m.html + m.text), `${name}: no Firebase wording`);
    assert(!/free|winner|urgent|act now|!!/i.test(m.subject), `${name}: calm subject`);
    assert(m.text.length > 80 && !/<[a-z]/i.test(m.text), `${name}: plain-text version`);
  }
});

Deno.test("one primary action each, links never printed raw in the HTML", () => {
  const primaries = (h: string) => (h.match(/background:#BF4409;border:1px solid #BF4409/g) ?? []).length;
  for (const [name, m] of all) {
    const expected = name === "verification" || name === "mfa" ? 0 : 1;
    assert(primaries(m.html) === expected, `${name}: ${expected} primary button(s), got ${primaries(m.html)}`);
    assert(!/>https:\/\/[^<]{40,}</.test(m.html), `${name}: no long raw URL as text`);
  }
  assert(all[0][1].html.includes("048 213"), "verification: big spaced code");
  assert(all[1][1].html.includes("v:roundrect"), "Outlook gets a VML button");
  assert(all[1][1].text.includes(link), "text part carries the link");
});

Deno.test("expiry and the 'ignore' line where an action was requested", () => {
  assert(all[1][1].text.includes("This link expires in 30 minutes and works once."), "reset expiry");
  assert(all[2][1].text.includes("This link expires in 1 hour and works once."), "change expiry in hours");
  for (const [name, m] of all.slice(0, 3)) assert(/If you didn't request this, you can/.test(m.text), `${name}: ignore line`);
  assert(all[3][1].text.includes("Secure your account") && all[4][1].text.includes("Secure your account"), "secure buttons");
  assert(all[4][1].text.includes("Chrome on Windows"), "device");
});

Deno.test("links must be https", () => {
  let threw = false;
  try { renderPasswordResetEmail({ url: "http://x.test/reset", expiresMinutes: 30 }); } catch (_) { threw = true; }
  assert(threw, "plain http refused");
});

Deno.test("button labels the person sees", () => {
  assert(all[1][1].html.includes(">Change your password here</a>"), "reset button");
  assert(all[1][1].subject === "Reset your Melai Nuts password", "reset subject");
  assert(all[2][1].html.includes(">Confirm email change</a>"), "change-confirm button");
});

Deno.test("greeting: first name only, cleaned, 'Hi there' without one", () => {
  assert(greetingName("Maria Santos") === "Maria", "first name");
  assert(greetingName("  josé  ") === "josé", "trimmed, accents kept");
  assert(greetingName("<b>Bob</b>") === null, "markup never reaches the greeting");
  assert(greetingName("Ana<script>") === "Ana", "symbols stripped");
  assert(greetingName("http://evil.test") === "http", "no link survives (':' and '/' are dropped)");
  assert(greetingName("") === null && greetingName(null) === null && greetingName("1234") === null, "nothing usable");
  const m = renderPasswordResetEmail({ url: link, expiresMinutes: 30 });
  assert(m.html.includes("Hi there,") && m.text.includes("Hi there,"), "fallback greeting");
});
