import { Resend } from "resend";

/**
 * Transactional email via Resend. Activates when RESEND_API_KEY is set;
 * otherwise emails are no-ops (in-app notifications still fire).
 */
const API_KEY = process.env.RESEND_API_KEY;
const FROM = process.env.EMAIL_FROM || "MoolaHub <onboarding@resend.dev>";

let client: Resend | null = null;
function resend(): Resend | null {
  if (!API_KEY) return null;
  if (!client) client = new Resend(API_KEY);
  return client;
}

export function emailEnabled(): boolean {
  return Boolean(API_KEY);
}

export function appUrl(path = "/"): string {
  const base = process.env.APP_URL || process.env.REPLIT_DEV_DOMAIN
    ? (process.env.APP_URL || `https://${process.env.REPLIT_DEV_DOMAIN}`)
    : "http://localhost:5000";
  return `${base.replace(/\/$/, "")}${path.startsWith("/") ? path : `/${path}`}`;
}

export async function sendEmail(params: {
  to: string;
  subject: string;
  html: string;
  text?: string;
}): Promise<void> {
  const r = resend();
  if (!r) return;
  try {
    await r.emails.send({
      from: FROM,
      to: params.to,
      subject: params.subject,
      html: params.html,
      text: params.text,
    });
  } catch (e) {
    console.error("[email] send failed:", e);
  }
}

/** Escape user-controlled strings before embedding them in HTML email markup. */
function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#x27;");
}

/**
 * Sanitize a URL for use in email href attributes.
 * Only http and https schemes are allowed; anything else is replaced with a
 * safe fallback so injected `javascript:` or `data:` URIs cannot execute.
 */
function sanitizeHref(href: string): string {
  try {
    const url = new URL(href);
    if (url.protocol === "http:" || url.protocol === "https:") return href;
  } catch {
    // fall through to safe fallback
  }
  return "#";
}

export function brandedEmail(opts: {
  heading: string;
  body: string;
  cta?: { label: string; href: string };
}): string {
  const safeHeading = escapeHtml(opts.heading);
  const safeBody = escapeHtml(opts.body);
  const button = opts.cta
    ? `<a href="${sanitizeHref(opts.cta.href)}" style="display:inline-block;background:#0E9E6E;color:#fff;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600;font-family:Inter,Arial,sans-serif;">${escapeHtml(opts.cta.label)}</a>`
    : "";
  return `<!doctype html><html><body style="margin:0;background:#F5F8F6;padding:32px 0;font-family:Inter,Arial,sans-serif;color:#0C1512;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
    <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:16px;overflow:hidden;border:1px solid #E4ECE8;">
      <tr><td style="background:#0C1512;padding:20px 28px;color:#fff;font-weight:700;font-size:18px;letter-spacing:-0.01em;">MoolaHub</td></tr>
      <tr><td style="padding:28px;">
        <h1 style="margin:0 0 12px;font-size:20px;color:#0C1512;">${safeHeading}</h1>
        <p style="margin:0 0 22px;font-size:15px;line-height:1.6;color:#3A4A44;">${safeBody}</p>
        ${button}
      </td></tr>
      <tr><td style="padding:18px 28px;border-top:1px solid #E4ECE8;font-size:12px;color:#8A9A93;">Social savings on Base. You're receiving this because you have a MoolaHub account.</td></tr>
    </table>
  </td></tr></table>
</body></html>`;
}

/**
 * Security heads-up sent after a password reset or change. Carries no code or
 * link to act on — it only confirms the change happened and tells the user what
 * to do if it wasn't them. No-ops without RESEND_API_KEY via sendEmail.
 */
export async function sendPasswordChangedEmail(to: string, name: string): Promise<void> {
  const body =
    `Hi ${name}, your MoolaHub password was just changed. If this was you, no action is needed. ` +
    `If you didn't make this change, your email may be compromised — please contact support right away.`;
  await sendEmail({
    to,
    subject: "Your MoolaHub password was changed",
    html: brandedEmail({ heading: "Your password was changed", body }),
    text: body,
  });
}
