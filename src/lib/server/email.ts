import "server-only";
import { Resend } from "resend";

/**
 * Email delivery via Resend. Activates when RESEND_API_KEY is set (production
 * secret); otherwise logs to the server console so dev/test flows still work.
 */
const KEY = process.env.RESEND_API_KEY;
const FROM = process.env.EMAIL_FROM || "MoolaHub <noreply@moolahub.io>";
const resend = KEY ? new Resend(KEY) : null;

export function emailEnabled() {
  return Boolean(resend);
}

export function appUrl(path = "") {
  const base = process.env.APP_URL || "http://localhost:3000";
  return `${base}${path}`;
}

export async function sendEmail(opts: {
  to: string;
  subject: string;
  html: string;
  text?: string;
}): Promise<{ sent: boolean }> {
  if (!resend) {
    console.log(`[email:dev] to=${opts.to} · subject="${opts.subject}"`);
    return { sent: false };
  }
  try {
    await resend.emails.send({
      from: FROM,
      to: opts.to,
      subject: opts.subject,
      html: opts.html,
      text: opts.text,
    });
    return { sent: true };
  } catch (e) {
    console.error("[email] send failed:", e);
    return { sent: false };
  }
}

/** Minimal branded wrapper for transactional emails. */
export function brandedEmail(opts: { heading: string; body: string; cta?: { label: string; href: string } }) {
  const button = opts.cta
    ? `<a href="${opts.cta.href}" style="display:inline-block;background:#0E9E6E;color:#fff;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:999px;margin-top:18px">${opts.cta.label}</a>`
    : "";
  return `
  <div style="background:#F5F8F6;padding:32px 0;font-family:Inter,Arial,sans-serif">
    <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:20px;padding:32px;border:1px solid rgba(12,21,18,.07)">
      <div style="font-family:Poppins,Arial,sans-serif;font-weight:800;font-size:20px;color:#0C1512">Moola<span style="color:#0E9E6E">Hub</span></div>
      <h1 style="font-family:Poppins,Arial,sans-serif;font-size:22px;color:#0C1512;margin:20px 0 8px">${opts.heading}</h1>
      <p style="color:#3A5046;line-height:1.6;margin:0">${opts.body}</p>
      ${button}
      <p style="color:#5C7468;font-size:12px;margin-top:28px">Save Now. Grow Together. · Built on Stellar</p>
    </div>
  </div>`;
}
